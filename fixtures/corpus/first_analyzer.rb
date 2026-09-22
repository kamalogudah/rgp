# Regression corpus fixture for the first analyzer gate.
#
# Hand-reviewed expected counts:
#   module:   1
#   class:    1
#   def:      1
#   if:       1
#   unless:   1
#   case:     1
#   while:    1
#   until:    1
#   for:      1
#   each:     1
#   times:    1
#   map:      1
#   collect:  1
#   select:   1
#   filter:   1
#   reject:   1
#   reduce:   1
#   inject:   1
#   size:     1
#   length:   1
#   count:    1
#   rescue:   1
#   block:    9
#   total observations: 34
#
# This fixture is an original RGP regression artifact. It does not depend on
# any external repository and is analyzed offline by the release gate test.
module FirstAnalyzer
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
