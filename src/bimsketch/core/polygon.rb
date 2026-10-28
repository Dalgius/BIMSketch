# frozen_string_literal: true

module BIMSketch
  # Poligoni nel piano (modulo puro Ruby): punti [x, y].
  module Polygon
    module_function

    # Area con segno (positiva per i poligoni antiorari).
    def signed_area(poly)
      sum = 0.0
      poly.each_with_index do |p, i|
        q = poly[(i + 1) % poly.size]
        sum += p[0] * q[1] - q[0] * p[1]
      end
      sum / 2.0
    end

    # Il punto è strettamente dentro il poligono? (ray casting)
    def contains?(poly, pt)
      x, y = pt
      inside = false
      j = poly.size - 1
      poly.each_with_index do |(xi, yi), i|
        xj, yj = poly[j]
        inside = !inside if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi
        j = i
      end
      inside
    end

    # I segmenti ab e cd si attraversano (escluse le sovrapposizioni agli estremi)?
    def segments_cross?(a, b, c, d)
      d1 = orient(c, d, a)
      d2 = orient(c, d, b)
      d3 = orient(a, b, c)
      d4 = orient(a, b, d)
      ((d1.positive? && d2.negative?) || (d1.negative? && d2.positive?)) &&
        ((d3.positive? && d4.negative?) || (d3.negative? && d4.positive?))
    end

    def orient(a, b, c)
      (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    end

    # Il poligono inner sta tutto dentro outer, senza toccarne i lati?
    def inside?(inner, outer)
      return false unless inner.all? { |p| contains?(outer, p) }

      edges(inner).none? { |a, b| edges(outer).any? { |c, d| segments_cross?(a, b, c, d) } }
    end

    # I due poligoni si sovrappongono (un vertice dentro l'altro o lati che si incrociano)?
    def overlap?(p, q)
      p.any? { |pt| contains?(q, pt) } || q.any? { |pt| contains?(p, pt) } ||
        edges(p).any? { |a, b| edges(q).any? { |c, d| segments_cross?(a, b, c, d) } }
    end

    def edges(poly)
      poly.each_with_index.map { |p, i| [p, poly[(i + 1) % poly.size]] }
    end

    # Rettangolo allineato agli assi da due vertici opposti (antiorario).
    def rect(p, q)
      x0, x1 = [p[0], q[0]].minmax
      y0, y1 = [p[1], q[1]].minmax
      [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]
    end
  end
end
