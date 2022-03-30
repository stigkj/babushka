module Babushka
  class LambdaChooser
    attr_reader :owner

    def var(name, opts = {}) owner.var(name, opts) end

    def initialize owner, *possible_choices, &block
      raise ArgumentError, "You can't use :otherwise as a choice name, because it's reserved." if possible_choices.include?(:otherwise)
      @owner = owner
      @possible_choices = possible_choices.push(:otherwise)
      @block = block
      @results = {}
    end

    def choose choices, method_name = nil
      metaclass.send :alias_method, method_name, :on unless method_name.nil?
      block_result = instance_eval(&@block)
      @results.empty? ? block_result : [choices].flatten(1).push(:otherwise).pick {|c| @results[c] }
    end

    def otherwise first = nil, *rest, &block
      on :otherwise, first, *rest, &block
    end

    def on choices, first = nil, *rest, &block
      raise "You can supply values or a block, but not both." if first && block

      [choices].flatten(1).each {|choice|
        raise "The choice '#{choice}' isn't valid." unless @possible_choices.include?(choice)

        @results[choice] = if block
          block
        elsif first.is_a? Hash
          first
        else
          [first].flatten(1).concat(rest)
        end
      }
    end

    # Make dep unmeetable because the platform isn't supported
    #
    # Should be used in a lambda chooser choice, like this:
    #
    #   requires {
    #     on :linux, 'some other dep'
    #     on :osx { unsupported_platform! }
    #   }
    #
    # You can use "otherwise", too:
    #
    #   requires {
    #     on :osx, 'go do the thing'
    #     otherwise { unsupported_platform! }
    #   }
    #
    # This will call "unmeetable!" on the dep if the platform matches,
    # and will have a predefined error message.
    def unsupported_platform!
      file, line = owner.source_location
      owner.unmeetable! <<-END.gsub(/ {8}/, '')
        I don't know how to install '#{owner.name}' on #{system}.
        You could teach me how! The dep is in #{file}:#{line}.
      END
    end

    private

    def metaclass
      class << self; self end
    end

    # The current platform
    def system
      "#{Babushka.host.system} #{Babushka.host.release}"
    end
  end
end
