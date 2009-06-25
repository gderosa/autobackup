class Partition
  attr_reader :dev, :fstype
  
  def initialize(dev) 
    @dev = dev
    @fstype = "unknown"
  end
  def mount
  end
  def umount
  end
end
