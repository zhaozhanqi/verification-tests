module BushSlicer
  # @note represents an OpenShift environment SystemUser (undocumented it seems)
  class SystemUser
    attr_reader :name, :env

    def initialize(name:, env:)
      @name = name
      @env = env
    end

    ############### take care of object comparison ###############
    def ==(p)
      p.kind_of?(self.class) && name == p.name && env == p.env
    end
    alias eql? ==

    def hash
      self.class.name.hash ^ name.hash ^ env.hash
    end
  end
end
