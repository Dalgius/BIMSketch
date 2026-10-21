# frozen_string_literal: true

module BIMSketch
  # Giunti d'angolo tra muri disegnati in sequenza (modulo puro Ruby, piano xy).
  #
  # Un muro va dal suo punto iniziale al finale lungo la direzione d e occupa
  # la fascia tra gli scostamenti lo..hi misurati lungo la normale sinistra
  # n = (-d.y, d.x). Al giunto il muro precedente prosegue fino a coprire
  # l'angolo e il successivo parte dalla faccia più lontana del precedente:
  # con angoli retti i due muri si toccano senza sovrapposizioni né vuoti.
  module WallJoint
    MIN_SIN = 0.02 # sotto ~1° i muri sono considerati allineati: nessun giunto

    module_function

    # Fascia occupata dal muro rispetto all'asse di disegno.
    def band(align, thickness)
      case align
      when 'left' then [0.0, thickness]
      when 'right' then [-thickness, 0.0]
      else [-thickness / 2.0, thickness / 2.0]
      end
    end

    # Fascia vista percorrendo il muro al contrario.
    def flip(band)
      [-band[1], -band[0]]
    end

    # Giunto tra il muro A (direzione d_a, fascia band_a) che termina
    # nell'angolo e il muro B (direzione d_b, fascia band_b) che vi inizia.
    # Restituisce [ext_end_a, trim_start_b]: di quanto prolungare A oltre
    # l'angolo e di quanto accorciare B all'inizio.
    def corner(d_a, d_b, band_a, band_b)
      cross = d_a[0] * d_b[1] - d_a[1] * d_b[0]
      return [0.0, 0.0] if cross.abs < MIN_SIN

      n_a = [-d_a[1], d_a[0]]
      n_b = [-d_b[1], d_b[0]]
      along_a = []
      along_b = []
      band_a.each do |u|
        band_b.each do |v|
          q = [v * n_b[0] - u * n_a[0], v * n_b[1] - u * n_a[1]]
          along_a << (q[0] * d_b[1] - q[1] * d_b[0]) / cross
          along_b << (q[0] * d_a[1] - q[1] * d_a[0]) / cross
        end
      end
      [along_a.max, along_b.max]
    end

    def direction(p, q)
      dx = q[0] - p[0]
      dy = q[1] - p[1]
      len = Math.hypot(dx, dy)
      len.zero? ? [0.0, 0.0] : [dx / len, dy / len]
    end

    # Prolungamenti [ext_start, ext_end] di ogni muro di una catena di punti
    # [[x, y], ...]. Se closed, l'ultimo punto si ricollega al primo (che non
    # va ripetuto).
    def chain(points, lo, hi, closed: false)
      segs = points.each_cons(2).to_a
      segs << [points.last, points.first] if closed && points.size > 2
      exts = segs.map { [0.0, 0.0] }
      pairs = (0...segs.size - 1).map { |i| [i, i + 1] }
      pairs << [segs.size - 1, 0] if closed && segs.size > 2
      pairs.each do |i, j|
        ext_end, trim = corner(direction(*segs[i]), direction(*segs[j]), [lo, hi], [lo, hi])
        exts[i][1] = ext_end
        exts[j][0] = -trim
      end
      exts
    end
  end
end
