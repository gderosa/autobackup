class Partition

  attr_reader :dev, :fstype, :kernel_id, :pn, :size, :start, :end

  Mount_base = "/mnt/target/"
  
  def initialize(args) 
    @dev = args[:dev]
    @pn = args[:pn]
    @fstype = args[:fstype]
    @kernel_id = args[:kernel_id]
    @size = args[:size]
    @start = args[:start]
    @end = args[:end]
  end

  def backup(sftp, dir)
    r = case @fstype
    when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs"
      IO.popen(\
        "partimage -V0 -d -o -z0 -Bx=y save #@dev stdout | gzip --fast -c",
        'r'
      )
    when "ntfs"
      IO.popen(\
        "ntfsclone -s -O - #@dev | gzip --fast -c",
        'r'
      )
    else
      return
    end

    w = sftp.file.open(dir + "/" + "part.img.gz", "w")
    while str = r.sysread(128*1024)
      w.write str
    end

    r.close
    w.close
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
