require 'fileutils'

class Partition

  attr_reader :dev, :fstype, :kernel_id, :pn, :size, :start, :end, :mountpoint

  Mount_base = "./mnt"
  Image_file_name = "img"
  Archive_file_name = "files"
  
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

  def backup(h)
    dir = h[:volumedir]
    passphrase = h[:passphrase]
    partimage = "partimage -g0 -c -V0 -d -o -z0 -Bx=y save #@dev stdout"
    ntfsclone = "ntfsclone --rescue -f -s -O - #@dev"
    gzip = "gzip --fast -c"
    dest_file = nil
    dest_file_partial = nil
    cmd = nil

    case @fstype
    
    when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs", \
      "ext2", "ext3", "xfs", "jsf", "reiserfs"
      dest_file = dir + "/" + Image_file_name + '.gz'
      dest_file_partial = dest_file + '.partial'
      cmd = partimage + " | " + gzip + " > " + dest_file_partial

    when "ntfs"
      dest_file = dir + "/" + Image_file_name
      dest_file_partial = dest_file + '.partial'
      cmd = ntfsclone + " | " + gzip + " > " + dest_file_partial

    else
      return

    end

    # rename dest_file.partial to dest_file only on success
    if system("sudo #{cmd}")  
      FileUtils.mv(dest_file_partial, dest_file)
    end

    # Now, make a files archive (use DAR http://dar.linux.free.fr/ )  
    dest_archive = File.expand_path(dir + '/' + Archive_file_name)
    mount_type = case @fstype
                 when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs"
                   'vfat'
                 when "ntfs"
                   'ntfs' # I believe kernel-based RO NTFS is fast
                 else
                   @fstype
                 end

    mount({:options => 'ro', :type => mount_type}) unless mounted?
    #puts "#@dev -> #@mountpoint -> #{dest_archive}"
    cmd = "dar -v -z1 -M --no-warn -R #@mountpoint -c #{dest_archive} "
    cmd << '-K "blowfish:' << passphrase << '" ' if passphrase
    cmd << '--alter=no-case '
    if @fstype == 'ntfs'
      cmd << '-X hiberfil.sys -X pagefile.sys -P "System Volume Information" '
    end
    cmd << '-Z "*.cab" -Z "*.zip" -Z "*.gz" -Z "*.bz2" -Z "*.lz*" -Z "*.jar" '
    cmd << '-Z "*.png" -Z "*.gif" -Z "*.jp*g" '
    cmd << '-Z "*.mp*" -Z "*.avi" -Z "*.mov" -Z "*.wm*" '
    system "sudo #{cmd}"
    umount

  end

  def restore(dir, fstype)
    partimage = "partimage -g0 -V0 -d -Bx=y restore #@dev stdin"
    ntfsclone = "ntfsclone -r -O #@dev -"
    img_file = dir + "/" + Image_file_name

    File.stat img_file # raises an exception if not found

    cmd = case fstype
    
    when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs", \
      "ext2", "ext3", "xfs", "jsf", "reiserfs"
      "gunzip -c #{img_file} | " + partimage 

    when "ntfs"
      "gunzip -c #{img_file} | " + ntfsclone

    else
      return

    end

    system("sudo #{cmd}")
  end
 

  def mounted?
    return true if @mountpoint
    return false
  end

  def mount(h)
    mountpoint = h[:mountpoint] || "#{Mount_base}/#{File.basename @dev}"
    type = h[:type] || 'auto'
    options = h[:options] ? "-o #{h[:options]}" : ""
    Dir.mkdir(mountpoint) unless File.directory?(mountpoint)
    if system("sudo mount -t #{type} #@dev #{mountpoint} #{options}") 
      @mountpoint = File.expand_path mountpoint
      return true
    else
      return false
    end
  end

  def umount
    if mounted?
      if system("sudo umount #@dev 2> /dev/null")
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
