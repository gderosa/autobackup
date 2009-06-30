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

  # Open a new ssh connection, executing ssh as a shell command.
  # I/O is delegated to the OS. As far as we cat test, this is the fastest 
  # solution.
  def backup(conf, dir)
    partimage = "partimage -V0 -d -o -z0 -Bx=y save #@dev stdout"
    ntfsclone = "ntfsclone -s -O - #@dev"
    gzip = "gzip --fast -c"
    ssh = "ssh -o CheckHostIp=no -o StrictHostKeyChecking=no" 
    ssh += " #{conf['user']}@#{conf['server']} "
    remote_file = dir + "/" + Image_file_name
    remote_cmd = "'cat > #{remote_file}'"
    ssh += " #{remote_cmd} "

    cmd = case @fstype
    when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs"
      partimage + " | " + gzip + " | " + ssh
    when "ntfs"
      ntfsclone + " | " + gzip + " | " + ssh
    else
      return
    end

    t_i = `date +%s`.to_i
    system(cmd) 
    t_f = `date +%s`.to_i

    puts "TIME ELAPSED"
    print t_f - t_i
    puts "s"

  end

=begin
  # The elegant, pure-Ruby solution is slower...
  def backup(sftp, dir)
    t_i = `date +%s`.to_i
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
    
    w = sftp.file.open(dir + "/" + Image_file_name, "w")
   
    bufsiz = 64*1024
    begin
      loop { w.write r.sysread(bufsiz) } 
    rescue EOFError
      # do nothing, go on
    end 

    t_f = `date +%s`.to_i

    puts "ELAPSED TIME"
    puts t_f - t_i

    r.close
    w.close
  end
=end

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
