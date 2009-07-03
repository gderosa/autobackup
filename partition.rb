require 'ftools'

class Partition

  attr_reader :dev, :fstype, :kernel_id, :pn, :size, :start, :end, :mountpoint

  Mount_base = "/mnt/target"
  Image_file_name = "img.gz"
  
  def initialize(args) 
    @dev = args[:dev]
    @pn = args[:pn]
    @fstype = args[:fstype]
    @kernel_id = args[:kernel_id]
    @size = args[:size]
    @start = args[:start]
    @end = args[:end]
    @mountpoint = find_mountpoint
  end

  def backup(conf, dir)
    partimage = "partimage -g0 -c -V0 -d -o -z0 -Bx=y save #@dev stdout"
    ntfsclone = "ntfsclone --rescue -s -O - #@dev"
    gzip = "gzip --fast -c"
    dest_file = dir + "/" + Image_file_name
    File.mv(dest_file, dest_file + ".old") if File.exists?(dest_file)
    dest_file_partial = dest_file + ".partial"

    cmd = case @fstype
    
    when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs", \
      "ext2", "ext3", "xfs", "jsf", "reiserfs"
      partimage + " | " + gzip + " > " + dest_file_partial

    when "ntfs"
      ntfsclone + " | " + gzip + " > " + dest_file_partial

    else
      return

    end

    # rename dest_file.partial to dest_file only on success
    if system(cmd) 
      File.mv(dest_file_partial, dest_file)
    end

  end

  def mounted?
    return true if @mountpoint
    return false
  end

  def mount(mountpoint="#{Mount_base}/#@dev")
    File.makedirs(mountpoint) unless File.directory?(mountpoint)
    if system("mount #@dev #{mountpoint}") 
      @mountpoint = mountpoint
      return true
    else
      return false
    end
  end

  def umount
    if mounted?
      if system("umount #@dev 2> /dev/null")
        @mountpoint = nil
        return true
      else
        return false
      end
    else
      return false
    end
  end

  def find_mountpoint
    mountpoint = nil
    File.read("/proc/mounts").each_line do |line|
      if line =~ /^(\S+) (\S+) /
        begin
          if @dev == $1 or @dev == File.readlink!($1)
            mountpoint = $2 
          end
        rescue
        end
      end
    end
    return mountpoint
  end

end
