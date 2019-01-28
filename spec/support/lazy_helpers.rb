# frozen_string_literal: true
module LazyHelpers
  MAGIC_NUMBER_WITH_LAZY_AUTHORIZED_HOOK = 44
  MAGIC_NUMBER_THAT_RETURNS_NIL = 0
  MAGIC_NUMBER_THAT_RAISES_ERROR = 13
  class Wrapper
    def initialize(item = nil, &block)
      if block
        @block = block
      else
        @item = item
      end
    end

    def item
      if @block
        @item = @block.call()
        @block = nil
      end
      @item
    end
  end

  # This is like the `Wrapper` but it will only evaluate a `value` if the block
  # has been executed. This allows for testing that the `execute` block has in
  # fact been called before the value has been accessed. While this is not a
  # requirement in real applications (the `value` method could also call
  # `execute` if it has not yet been called) this simplified class makes testing
  # easier.
  class ConcurrentWrapper
    attr_reader :value

    def initialize(&block)
      @block = block
    end

    def execute
      @value = @block.call
    end
  end

  class SumAll
    attr_reader :own_value
    attr_writer :value

    def initialize(own_value)
      @own_value = own_value
      all << self
    end

    def value
      @value ||= begin
        total_value = all.map(&:own_value).reduce(&:+)
        all.each { |v| v.value = total_value}
        all.clear
        total_value
      end
      @value
    end

    def all
      self.class.all
    end

    def self.all
      @all ||= []
    end
  end

  class ConcurrentSumAll
    attr_reader :own_value
    attr_accessor :value

    def initialize(own_value)
      @own_value = own_value
      all << self
    end

    def execute
      @value = begin
        total_value = all.map(&:own_value).reduce(&:+)
        all.each { |v| v.value = total_value}
        all.clear
        total_value
      end
    end

    def all
      self.class.all
    end

    def self.all
      @all ||= []
    end
  end

  class LazySum < GraphQL::Schema::Object
    field :value, Integer, null: true
    def value
      if object == MAGIC_NUMBER_THAT_RAISES_ERROR
        nil
      else
        object
      end
    end

    def self.authorized?(obj, ctx)
      if obj == MAGIC_NUMBER_WITH_LAZY_AUTHORIZED_HOOK
        Wrapper.new { true }
      else
        true
      end
    end

    field :nestedSum, LazySum, null: false do
      argument :value, Integer, required: true
    end

    def nested_sum(value:)
      if value == MAGIC_NUMBER_THAT_RAISES_ERROR
        Wrapper.new(nil)
      else
        SumAll.new(@object + value)
      end
    end

    field :nullableNestedSum, LazySum, null: true do
      argument :value, Integer, required: true
    end
    alias :nullable_nested_sum :nested_sum
  end

  class ConcurrentSum < GraphQL::Schema::Object
    field :value, Integer, null: true, resolve: ->(o, a, c) { o }
    field :concurrentNestedSum, ConcurrentSum, null: false do
      argument :value, Integer, required: true
    end

    def concurrent_nested_sum(value:)
      ConcurrentWrapper.new { @object + value }
    end
  end

  using GraphQL::DeprecatedDSL
  if RUBY_ENGINE == "jruby"
    # JRuby doesn't support refinements, so the `using` above won't work
    GraphQL::DeprecatedDSL.activate
  end

  class LazyQuery < GraphQL::Schema::Object
    field :int, Integer, null: false do
      argument :value, Integer, required: true
      argument :plus, Integer, required: false, default_value: 0
    end
    def int(value:, plus:)
      Wrapper.new(value + plus)
    end

    field :concurrent_int, Integer, null: false do 
      argument :value, Integer, required: true 
      argument :plus, Integer, required: false, default_value: 0 
    end 
    
    def concurrent_int(value:, plus:)
      ConcurrentWrapper.new { value + plus }
    end 
    
    field :concurrent_nested_sum, ConcurrentSum, null: false do 
      argument :value, Integer, required: true 
    end 
    
    def concurrent_nested_sum(value:)
      ConcurrentSumAll.new(args[:value])
    end

    field :nested_sum, LazySum, null: false do
      argument :value, Integer, required: true
    end

    def nested_sum(value:)
      SumAll.new(value)
    end

    field :nullable_nested_sum, LazySum, null: true do
      argument :value, Integer, required: true
    end

    def nullable_nested_sum(value:)
      if value == MAGIC_NUMBER_THAT_RAISES_ERROR
        Wrapper.new { raise GraphQL::ExecutionError.new("#{MAGIC_NUMBER_THAT_RAISES_ERROR} is unlucky") }
      elsif value == MAGIC_NUMBER_THAT_RETURNS_NIL
        nil
      else
        SumAll.new(value)
      end
    end

    field :list_sum, [LazySum, null: true], null: true do
      argument :values, [Integer], required: true
    end
    def list_sum(values:)
      values.map { |v| v == MAGIC_NUMBER_THAT_RETURNS_NIL ? nil : v }
    end
  end

  class SumAllInstrumentation
    def initialize(counter:)
      @counter = counter
    end

    def before_query(q)
      add_check(q, "before #{q.selected_operation.name}")
      # TODO not threadsafe
      # This should use multiplex-level context
      SumAll.all.clear
    end

    def after_query(q)
      add_check(q, "after #{q.selected_operation.name}")
    end

    def before_multiplex(multiplex)
      add_check(multiplex, "before multiplex #@counter")
    end

    def after_multiplex(multiplex)
      add_check(multiplex, "after multiplex #@counter")
    end

    def add_check(obj, text)
      checks = obj.context[:instrumentation_checks]
      if checks
        checks << text
      end
    end
  end

  class LazySchema < GraphQL::Schema
    query(LazyQuery)
    mutation(LazyQuery)
    lazy_resolve(Wrapper, :item)
    lazy_resolve(ConcurrentWrapper, :value, :execute)
    lazy_resolve(SumAll, :value)
    lazy_resolve(ConcurrentSumAll, :value, :execute)
    instrument(:query, SumAllInstrumentation.new(counter: nil))
    instrument(:multiplex, SumAllInstrumentation.new(counter: 1))
    instrument(:multiplex, SumAllInstrumentation.new(counter: 2))

    if TESTING_INTERPRETER
      use GraphQL::Execution::Interpreter
      use GraphQL::Analysis::AST
    end

    def self.sync_lazy(lazy)
      if lazy.is_a?(SumAll) && lazy.own_value > 1000
        lazy.value # clear the previous set
        lazy.own_value - 900
      else
        super
      end
    end
  end

  def run_query(query_str, **rest)
    LazySchema.execute(query_str, **rest)
  end
end
