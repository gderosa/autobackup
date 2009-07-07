class Array

  def how_many_in_common(other_array)
    return self.how_many_in_common_by(other_array, proc{|x,y|x==y})
  end

  def how_many_in_common_by(other_array, rel) 
    # rel is a general equivalence relation (a function pointer) 
    n = 0
    tmp = self.clone
    tmp_other = other_array.clone
    tmp.each_index do |i|
      tmp_other.each_index do |j|
        if tmp[i] != :MARKED and tmp_other[j] != :MARKED_OTHER
          if rel.call(tmp[i], tmp_other[j]) 
            tmp[i] = :MARKED
            tmp_other[j] = :MARKED_OTHER
            n += 1
          end
        end
      end
    end
    return n
  end

end

