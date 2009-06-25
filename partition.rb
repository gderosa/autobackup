class Partition

  attr_reader :dev, :fstype, :mountpoint

  Mount_base = "/mnt/target/"
  
  def initialize(args) 
    @dev = args[:dev]
    @mountpoint = args[:mountpoint]
    @fstype = args[:fstype]
    @fstype = getfstype if not @fstype
  end

  def getfstype
    if mounted?
      # do nothing
    else
      # do nothing
    end
    nil
  end

  def mounted?
    return true if @mountpoint
    return false
  end

  def mount
    if system("mount #@dev #{Mount_base}/#@dev") 
      @mountpoint = "#{Mount_base}/#@dev"
      @fstype = getfstype
      return true
    else
      return false
    end
  end

  def umount
    if mounted?
      if system("umount #@mountpoint")
        return true
      else
        return false
      end
    else
      return false
    end
  end

end
