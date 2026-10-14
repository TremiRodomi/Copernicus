# LZSS decoder for the X68000 data files (FS.X routine $3cc2/$3cdc; see NOTES.md pass 4).
# File = u32 (ignored) | u32 output size | stream. Flag byte LSB first, 1 = literal; match = b1,b2 ->
# ring pos ((b1 & $F0) << 4) | b2, length (b1 & $0F) + 3. 4 KB ring, write pos $FEE, pre-filled with the LZHUF dictionary.
module LZSS
  def self.ring
    r = []
    256.times { |v| 13.times { r << v } }
    256.times { |v| r << v }
    255.downto(0) { |v| r << v }
    128.times { r << 0 }
    110.times { r << 32 }
    r.concat(Array.new(4096 - r.size, 0))
  end

  # data: binary String. Returns an Array of byte values.
  def self.decode(data)
    size = (data.getbyte(4) << 24) | (data.getbyte(5) << 16) | (data.getbyte(6) << 8) | data.getbyte(7)
    ring = self.ring
    w = 0xFEE
    out = []
    p = 8
    n = data.bytesize
    while out.size < size && p < n
      flags = data.getbyte(p)
      p += 1
      8.times do |bit|
        break if out.size >= size
        if (flags >> bit) & 1 == 1
          c = data.getbyte(p)
          p += 1
          out << c
          ring[w] = c
          w = (w + 1) & 0xFFF
        else
          b1 = data.getbyte(p)
          b2 = data.getbyte(p + 1)
          p += 2
          pos = ((b1 & 0xF0) << 4) | b2
          ((b1 & 0x0F) + 3).times do
            c = ring[pos]
            pos = (pos + 1) & 0xFFF
            out << c
            ring[w] = c
            w = (w + 1) & 0xFFF
          end
        end
      end
    end
    raise "LZSS: decoded #{out.size} of #{size} bytes" if out.size != size
    out
  end
end
