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
    # It is possible to encrypt disk images and archives to comply
    # with privacy regulations.
    #
    # * disk images and tar.gz are piped to openssl (blowfish)
    # * DAR archive utility has its own encryption options (blowfish)
    # * 7z has its own encryption options (aes-256) 
    #
    dir = File.expand_path h[:volumedir]
    passphrase = h[:passphrase]
    partimage = "partimage -g0 -c -V0 -d -o -z0 -Bx=y save #@dev stdout"
    ntfsclone = "ntfsclone --rescue -f -s -O - #@dev"
    gzip = "gzip --fast -c"
    encrypt = "openssl enc -e -bf -pass pass:'#{passphrase}'"
    openssl_bf_encrypt = encrypt
    dest_file = dir + "/" + Image_file_name + '.gz'
    dest_file_partial = dest_file + '.partial'

    case @fstype
    
    when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs", \
      "ext2", "ext3", "xfs", "jsf", "reiserfs"
      cmd = "#{partimage} | #{gzip}"

    when "ntfs"
      cmd = "#{ntfsclone} | #{gzip}"

    else
      return

    end

    cmd << " | #{encrypt}" if h[:passphrase]
    cmd << " > " + dest_file_partial

    # rename dest_file.partial to dest_file only on success
    if $single_command == 'clone'
      if system("sudo #{cmd}")  
        FileUtils.mv(dest_file_partial, dest_file)
      end
    end

    # Now, make a files archive 
    dest_archive = File.expand_path(dir + '/' + Archive_file_name)
    mount_type = case @fstype
                 when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs"
                   'vfat'
                 when "ntfs"
                   'ntfs-3g' # NTFS-3g should be more robust
                 else
                   @fstype
                 end
    exclude_file_windows="#{ROOTDIR}/share/windows.exclude"

    mount({:options => 'ro', :type => mount_type}) unless mounted?
    #puts "#@dev -> #@mountpoint -> #{dest_archive}"

    case h[:archive_format]
    when :dar
      cmd = "dar -v -z1 -M --no-warn -R #@mountpoint -c #{dest_archive} "
      cmd << '-K "blowfish:' << passphrase << '" ' if passphrase
      cmd << '--alter=no-case '
      if @fstype == 'ntfs'
        cmd << '-X hiberfil.sys -X pagefile.sys -P "System Volume Information" '
      end
      cmd << '-Z "*.cab" -Z "*.zip" -Z "*.gz" -Z "*.bz2" -Z "*.lz*" -Z "*.jar" '
      cmd << '-Z "*.png" -Z "*.gif" -Z "*.jp*g" '
      cmd << '-Z "*.mp*" -Z "*.avi" -Z "*.mov" -Z "*.wm*" '
      system "sudo -E #{cmd}"
    when :"7z"
      exclude = ''
      exclude = "-x@#{exclude_file_windows}" if mount_type =~ /fat|ntfs/i
      encrypt = ''
      encrypt = "-mhe=on -p#{passphrase}" if passphrase
      cmd = "7z a #{exclude} #{encrypt} -m0=Deflate -ms=off -mhc=off -mx=1 #{dest_archive}.7z -w#{dir} ."
      #cmd << " -x@#{ROOTDIR}/share/ntfs.exclude" if @fstype == 'ntfs'
      system "cd #@mountpoint && sudo -E #{cmd}" 
    when :"tar.gz" 
      # if you choose tar.gz you're a Unix guy and you're supposed to know
      # how to make a pipe with openssl... aren't you?
      if passphrase
        cmd = "GZIP==--fast tar -C #@mountpoint cvz . | #{openssl_bf_encrypt} > #{dest_archive}.tar.gz.bf"
      else
        cmd = "GZIP==--fast tar -C #@mountpoint cvzf #{dest_archive}.tar.gz ."
      end
      system "sudo -E #{cmd}"
    end

    umount

  end

  def restore(dir, fstype, crypto_options=nil)
    partimage = "partimage -g0 -V0 -d -Bx=y restore #@dev stdin"
    ntfsclone = "ntfsclone -r -O #@dev -"
    img_file = dir + "/" + Image_file_name

    begin
      File.stat img_file # raises an exception if not found
    rescue Errno::ENOENT
      img_file = img_file + '.gz'
      File.stat img_file # raises an exception if not found
    end

    cmd = ''

    if crypto_options and crypto_options[:passphrase]
      cmd = "openssl enc -d -bf -pass pass:'#{crypto_options[:passphrase]}' -in #{img_file} | gunzip -c"
    else
      cmd = "gunzip -c #{img_file}"
    end

    cmd << ' | '

    cmd << case fstype
    
    when "vfat", "fat", "fat32", "fat16", "msdos", "msdosfs", \
        "ext2", "ext3", "xfs", "jsf", "reiserfs"
      "sudo #{partimage}"

    when "ntfs"
      "sudo #{ntfsclone}"

    else
      return

    end

    system(cmd)

    # There's no restore from DAR/TAR/7Z archive in *this* application.
  end
 

  def mounted?
    return true if @mountpoint
    return false
  end

  def mount(h={})
    begin
      mountpoint = h[:mountpoint] || "#{Mount_base}/#{File.basename @dev}"
    rescue
      puts $!
      pp h
      exit
    end
    type = h[:type] || 'auto'
    options = h[:options] ? "-o #{h[:options]}" : ""
    Dir.mkdir(mountpoint) unless File.directory?(mountpoint)
    if system("sudo -E mount -t #{type} #@dev #{mountpoint} #{options}") 
      @mountpoint = File.expand_path mountpoint
      return true
    else
      return false
    end
  end

  def umount
    if mounted?
      if system("sudo -E umount #@dev 2> /dev/null")
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
