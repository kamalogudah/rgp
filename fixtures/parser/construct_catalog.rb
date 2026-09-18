# Fixture for the initial construct measurement catalog.
# Each section uses a minimal, unambiguous form so the AST fixture tests can
# assert exact counts and receiver semantics.
module ConstructCatalog
  class Example
    def run(items)
      # Conditionals
      if items.empty?
        :empty
      end

      unless items.empty?
        :present
      end

      case items
      when []
        :none
      else
        :some
      end

      # Loops
      while false
        break
      end

      until true
        break
      end

      for item in items
        item
      end

      # Iteration
      items.each { |item| item }
      3.times do
        :tick
      end

      # Collection transformation
      [1, 2].map { |x| x }
      items.collect { |item| item }

      # Filtering
      items.select { |item| item }
      items.filter { |item| item }
      items.reject { |item| item }

      # Aggregation
      items.reduce(0) { |sum, n| sum + n }
      items.inject(0) { |sum, n| sum + n }

      # Cardinality
      items.size
      "hello".length
      [1, 2, 3].count

      # Exception handling
      raise :boom
    rescue StandardError
      :caught
    end
  end
end
