# frozen_string_literal: true

module BIMSketch
  # Giunti d'angolo tra muri (modulo puro Ruby, piano xy).
  #
  # Un muro va dal suo punto iniziale al finale lungo la direzione d e occupa
  # la fascia tra gli scostamenti lo..hi misurati lungo la normale sinistra
  # n = (-d.y, d.x). Le sue due facce laterali sono quindi le rette a
  # scostamento lo e hi.
  #
  # I giunti sono "a quartabuono": la faccia lo del muro che arriva
  # nell'angolo si interseca con la faccia lo del muro che parte, e lo stesso
  # per le facce hi. Il segmento tra le due intersezioni è la testata comune:
  # i muri si toccano senza vuoti né sovrapposizioni con qualunque angolo,
  # spessore e allineamento.
  #
  # Prolungamenti di un muro: [start_lo, start_hi, end_lo, end_hi], cioè di
  # quanto la faccia lo/hi si estende oltre il punto iniziale e oltre il
  # punto finale dell'asse (negativo = accorciata).
  module WallJoint
    MIN_SIN = 0.02 # sotto ~1° i muri sono considerati allineati: nessun giunto
    MAX_MITER = 6.0 # oltre 6 spessori (angoli molto acuti) il giunto non si applica

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

    # Prolungamenti visti percorrendo il muro al contrario.
    def flip_ext(ext)
      [ext[3], ext[2], ext[1], ext[0]]
    end

    # Prolungamenti nel formato a 4 valori (accetta anche il vecchio [inizio, fine]).
    def normalize_ext(ext)
      e = Array(ext).map(&:to_f)
      return [e[0], e[0], e[1], e[1]] if e.size == 2
      return e if e.size == 4

      [0.0, 0.0, 0.0, 0.0]
    end

    # Giunto tra il muro A (direzione d_a, fascia band_a) che termina
    # nell'angolo e il muro B (direzione d_b, fascia band_b) che vi inizia.
    # Restituisce [[end_lo_a, end_hi_a], [start_lo_b, start_hi_b]] oppure nil
    # se i muri sono allineati o l'angolo è troppo acuto.
    def corner(d_a, d_b, band_a, band_b)
      cross = d_a[0] * d_b[1] - d_a[1] * d_b[0]
      return nil if cross.abs < MIN_SIN

      n_a = [-d_a[1], d_a[0]]
      n_b = [-d_b[1], d_b[0]]
      limit = MAX_MITER * [band_a[1] - band_a[0], band_b[1] - band_b[0]].max
      ends = []
      starts = []
      [0, 1].each do |k|
        u = band_a[k]
        v = band_b[k]
        q = [v * n_b[0] - u * n_a[0], v * n_b[1] - u * n_a[1]]
        s = (q[0] * d_b[1] - q[1] * d_b[0]) / cross
        r = (q[0] * d_a[1] - q[1] * d_a[0]) / cross
        return nil if s.abs > limit || r.abs > limit

        ends << s
        starts << -r
      end
      [ends, starts]
    end

    def direction(p, q)
      dx = q[0] - p[0]
      dy = q[1] - p[1]
      len = Math.hypot(dx, dy)
      len.zero? ? [0.0, 0.0] : [dx / len, dy / len]
    end

    # Prolungamenti [start_lo, start_hi, end_lo, end_hi] di ogni muro di una
    # catena di punti [[x, y], ...]. Se closed, l'ultimo punto si ricollega al
    # primo (che non va ripetuto).
    def chain(points, lo, hi, closed: false)
      segs = points.each_cons(2).to_a
      segs << [points.last, points.first] if closed && points.size > 2
      exts = segs.map { [0.0, 0.0, 0.0, 0.0] }
      pairs = (0...segs.size - 1).map { |i| [i, i + 1] }
      pairs << [segs.size - 1, 0] if closed && segs.size > 2
      pairs.each do |i, j|
        joint = corner(direction(*segs[i]), direction(*segs[j]), [lo, hi], [lo, hi])
        next unless joint

        exts[i][2], exts[i][3] = joint[0]
        exts[j][0], exts[j][1] = joint[1]
      end
      exts
    end

    # Impronta del muro nel suo sistema locale (x lungo l'asse dal punto
    # iniziale, y = 0 sulla faccia lo, y = t sulla faccia hi):
    # [[x, 0], [x, 0], [x, t], [x, t]] in senso antiorario.
    def footprint(length, thickness, ext)
      e = normalize_ext(ext)
      [[-e[0], 0.0], [length + e[2], 0.0], [length + e[3], thickness], [-e[1], thickness]]
    end

    # Prolungamenti della fascia y0..y1 (0 <= y0 < y1 <= thickness) di un muro:
    # le testate oblique sono segmenti, quindi i valori si interpolano.
    def band_ext(ext, thickness, y0, y1)
      e = normalize_ext(ext)
      t = thickness.to_f
      f0 = t.positive? ? y0 / t : 0.0
      f1 = t.positive? ? y1 / t : 1.0
      [e[0] + (e[1] - e[0]) * f0, e[0] + (e[1] - e[0]) * f1,
       e[2] + (e[3] - e[2]) * f0, e[2] + (e[3] - e[2]) * f1]
    end

    # Tratto centrale del muro (stesso x su entrambe le facce): dove possono
    # stare porte e finestre. Restituisce [x_min, x_max].
    def core_range(length, ext)
      e = normalize_ext(ext)
      [[-e[0], -e[1]].max, [length + e[2], length + e[3]].min]
    end

    def area(polygon)
      sum = 0.0
      polygon.each_with_index do |p, i|
        q = polygon[(i + 1) % polygon.size]
        sum += p[0] * q[1] - q[0] * p[1]
      end
      sum.abs / 2.0
    end
  end
end
