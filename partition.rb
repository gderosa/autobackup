class Partition

  attr_reader :dev, :fstype, :kernel_id, :pn, :size, :start, :end

  Mount_base = "/mnt/target/"
  Image_file_name = "img.gz"
  
  def initialize(args) 
    @dev = args[:dev]
    @pn = args[:pn]
    @fstype = args[:fstype]
    @kernel_id = args[:kernel_id]
    @size = args[:size]
    @start = args[:start]
    @end = args[:end]
  end

  def backup(conf, dir)
    partimage = "partimage -g0 -c -V0 -d -o -z0 -Bx=y save #@dev stdout"
    ntfsclone = "ntfsclone -s -O - #@dev"
    gzip = "gzip --fast -c"
    dest_file = dir + "/" + Image_file_name

    cmd = case @fstype
    when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs", \
      "ext2", "ext3", "xfs", "jsf", "reiserfs"

      partimage + " | " + gzip + " > " + dest_file
    when "ntfs"
      ntfsclone + " | " + gzip + " > " + dest_file
    else
      return
    end

    system(cmd) 

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
