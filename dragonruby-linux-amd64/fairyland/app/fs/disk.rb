# Human68k 2HD floppy image reader (.hdm raw, .dim = 256-byte header + raw). FAT12, 1024-byte sectors.
# Only the root directory is needed: the game's files all live there.
module Disk
  BPS = 1024
  RESERVED = 1
  FATS = 2
  SECTORS_PER_FAT = 2
  ROOT_ENTRIES = 0xc0

  # Returns { "FS.X" => String, ... } or raises with a readable message.
  def self.root_files(image, dim:)
    d = dim ? image.byteslice(256, image.bytesize - 256) : image
    raise 'not a Human68k 2HD disk image' unless d.byteslice(0x12, 4) == "\x04\x00\x01\x02"
    fat_bytes = d.byteslice(RESERVED * BPS, SECTORS_PER_FAT * BPS)
    root_at = (RESERVED + FATS * SECTORS_PER_FAT) * BPS
    data0 = root_at + ROOT_ENTRIES * 32
    files = {}
    ROOT_ENTRIES.times do |i|
      e = root_at + i * 32
      first = d.getbyte(e)
      break if first == 0
      next if first == 0xE5
      attr = d.getbyte(e + 11)
      next if attr & 0x18 != 0 # volume label or directory
      name = d.byteslice(e, 8).delete(' ').delete("\0")
      ext = d.byteslice(e + 8, 3).delete(' ')
      name = "#{name}.#{ext}" unless ext.empty?
      cluster = d.getbyte(e + 26) | (d.getbyte(e + 27) << 8)
      size = d.getbyte(e + 28) | (d.getbyte(e + 29) << 8) | (d.getbyte(e + 30) << 16) | (d.getbyte(e + 31) << 24)
      chunks = []
      guard = 0
      while cluster >= 2 && cluster < 0xff0 && guard < 2000
        chunks << d.byteslice(data0 + (cluster - 2) * BPS, BPS)
        o = (cluster * 3).idiv(2)
        v = fat_bytes.getbyte(o) | (fat_bytes.getbyte(o + 1) << 8)
        cluster = cluster.odd? ? (v >> 4) : (v & 0xfff)
        guard += 1
      end
      files[name.upcase] = chunks.join.byteslice(0, size)
    end
    files
  end
end
