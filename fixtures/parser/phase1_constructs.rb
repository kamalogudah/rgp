module FixtureSyntax
  class Example
    def run(items)
      result = [1, { key: 2 }]

      if items.empty?
        result << :empty
      end

      unless items.empty?
        result << :present
      end

      case items
      when []
        :none
      else
        :some
      end

      while false
        break
      end

      until true
        break
      end

      for item in items
        result << item
      end

      items.each { |item| work(item) }
    rescue StandardError
      []
    end
  end
end
