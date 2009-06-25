class File
  
  # just like readlink -f from the shell
  def File.readlink!(path)
    path = File.expand_path(path)
    dirname = File.dirname(path)
    readlink = File.readlink(path)
    if not readlink =~ /^\//
      readlink = dirname + '/'+ readlink
    end
    readlink = File.expand_path(readlink) 
    if File.symlink?(readlink)
      return File.readlink!(readlink) 
    else
      return readlink
    end
  end

end

puts File.readlink!("/dev/disk/by-id/ata-FUJITSU_MHV2080BH_PL_NW9ZT6C37VVJ")
