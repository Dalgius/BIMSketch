# frozen_string_literal: true

require_relative 'polygon'

module BIMSketch
  # Contorno di un perimetro chiuso di muri (modulo puro Ruby).
  # Ogni muro è { a: [x, y], b: [x, y], band: [lo, hi] }: asse da a a b e
  # fascia del muro come scostamenti dall'asse lungo la normale sinistra
  # (vedi WallJoint.band). I muri devono toccarsi agli estremi dell'asse
  # (giunti d'angolo), uno dopo l'altro, a formare un solo anello.
  module WallLoop
    module_function

    # Poligono antiorario [[x, y], ...] della faccia esterna (side: :outer),
    # interna (:inner) o dell'asse (:axis) del perimetro; nil se i muri non
    # formano un anello chiuso.
    def outline(walls, side: :outer, tol: 1e-3)
      order = chain(walls, tol)
      return nil unless order

      starts = order.map { |i, fwd| fwd ? walls[i][:a] : walls[i][:b] }
      order = order.reverse.map { |i, fwd| [i, !fwd] } if Polygon.signed_area(starts).negative?
      lines = order.map do |i, fwd|
        w = walls[i]
        a, b = fwd ? [w[:a], w[:b]] : [w[:b], w[:a]]
        d = direction(a, b)
        lo, hi = w[:band]
        lo, hi = -hi, -lo unless fwd
        # Antiorario: l'esterno è a destra, cioè verso lo scostamento minore.
        off = { outer: lo, inner: hi }.fetch(side, 0.0)
        [[a[0] - d[1] * off, a[1] + d[0] * off], d]
      end
      pts = lines.each_with_index.map do |(p, d), i|
        q, e = lines[i - 1]
        intersect(q, e, p, d) || p
      end
      simplify(pts, tol)
    end

    # Ordine dei muri lungo l'anello: [[indice, percorso nel suo verso?], ...].
    def chain(walls, tol)
      return nil if walls.size < 3

      near = ->(p, q) { Math.hypot(p[0] - q[0], p[1] - q[1]) <= tol }
      order = [[0, true]]
      used = [0]
      point = walls[0][:b]
      loop do
        hits = walls.each_index.reject { |j| used.include?(j) && j != 0 }.flat_map do |j|
          w = walls[j]
          [near.call(w[:a], point) ? [j, true] : nil, near.call(w[:b], point) ? [j, false] : nil].compact
        end
        hits.reject! { |j, _| j == order.last[0] }
        return nil unless hits.size == 1

        j, fwd = hits.first
        return(used.size == walls.size && fwd ? order : nil) if j.zero?

        order << [j, fwd]
        used << j
        point = fwd ? walls[j][:b] : walls[j][:a]
      end
    end

    def direction(a, b)
      dx = b[0] - a[0]
      dy = b[1] - a[1]
      len = Math.hypot(dx, dy)
      [dx / len, dy / len]
    end

    # Intersezione delle rette p + t·d e q + s·e (nil se parallele).
    def intersect(p, d, q, e)
      cross = d[0] * e[1] - d[1] * e[0]
      return nil if cross.abs < 1e-9

      t = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / cross
      [p[0] + d[0] * t, p[1] + d[1] * t]
    end

    # Elimina vertici doppi e allineati.
    def simplify(pts, tol)
      out = pts.dup
      loop do
        idx = out.each_index.find do |i|
          a = out[i - 1]
          b = out[i]
          c = out[(i + 1) % out.size]
          Math.hypot(b[0] - a[0], b[1] - a[1]) <= tol || Polygon.orient(a, b, c).abs <= tol * tol
        end
        break unless idx && out.size > 3

        out.delete_at(idx)
      end
      out
    end
  end
end
