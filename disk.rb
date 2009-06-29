require 'partition'
class Disk
  attr_reader :kernel_id, :dev, :volumes, :size
  def initialize(args)
    @kernel_id = args[:kernel_id]
    @dev = args[:dev]
    @size = args[:size]
    @volumes = []
    args[:volumes].each do |vol|
      @volumes << Partition.new(vol)
    end
  end
end

