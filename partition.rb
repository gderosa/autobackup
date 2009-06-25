class Partition

  attr_reader :dev, :fstype, :mountpoint

  Mount_base = "/mnt/target/"
  
  def initialize(args) 
    @dev = args[:dev]
    @mountpoint = args[:mountpoint]
    @fstype = args[:fstype]
  end
  def getmount
  end
  def mounted?
  end
  def mount
  end
  def umount
  end
end
