# frozen_string_literal: true

module BIMSketch
  # Prospetto di un muro parametrico con aperture (modulo puro Ruby).
  # Coordinate nel piano del muro: x lungo il muro, z in altezza.
  # Un'apertura è [a, b, c, d]: da x = a a x = b, da z = c a z = d.
  # Le aperture che partono dalla base del muro (porte) diventano rientranze
  # del contorno; le altre (finestre) diventano fori interni.
  module WallProfile
    module_function

    def door?(opening, z0, eps)
      opening[2] <= z0 + eps
    end

    # Contorno esterno del prospetto come array di [x, z] (senza ripetere il
    # primo punto). Le porte devono essere comprese in [x0, x1] e non sovrapposte.
    def outline(x0, x1, z0, z1, openings, eps)
      doors = openings.select { |o| door?(o, z0, eps) }.sort_by(&:first)
      pts = [[x0, z0]]
      doors.each do |a, b, _c, d|
        pts.push([a, z0], [a, d], [b, d], [b, z0])
      end
      pts.push([x1, z0], [x1, z1], [x0, z1])
      simplify(pts, eps)
    end

    # Fori interni (finestre) come rettangoli di [x, z].
    def holes(openings, z0, eps)
      openings.reject { |o| door?(o, z0, eps) }.map do |a, b, c, d|
        [[a, c], [b, c], [b, d], [a, d]]
      end
    end

    # Elimina punti doppi e punti allineati con i vicini (anche i "ritorni"
    # che si creano quando una porta tocca l'estremità del muro).
    def simplify(points, eps)
      pts = points.dup
      loop do
        pts = pts.each_with_index.reject do |p, i|
          i.positive? && close?(p, pts[i - 1], eps)
        end.map(&:first)
        pts.pop while pts.size > 1 && close?(pts.last, pts.first, eps)
        n = pts.size
        idx = (0...n).find do |i|
          prev = pts[i - 1]
          nxt = pts[(i + 1) % n]
          cur = pts[i]
          cross = (cur[0] - prev[0]) * (nxt[1] - cur[1]) - (cur[1] - prev[1]) * (nxt[0] - cur[0])
          cross.abs <= eps * eps
        end
        break pts unless idx && n > 3

        pts.delete_at(idx)
      end
    end

    def close?(p, q, eps)
      (p[0] - q[0]).abs <= eps && (p[1] - q[1]).abs <= eps
    end

    # Verifica se una nuova apertura si sovrappone (o si avvicina oltre gap)
    # a quelle esistenti.
    def overlaps?(opening, others, gap)
      a, b, c, d = opening
      others.any? do |a2, b2, c2, d2|
        a < b2 + gap && b > a2 - gap && c < d2 + gap && d > c2 - gap
      end
    end

    # Vani allargati per il risvolto della finitura: ogni apertura [a, b, c, d]
    # si allarga di r su ogni lato (non in basso per le porte), senza uscire
    # da [x0, x1] x [z0, z1] e fermandosi a metà della distanza dalle aperture
    # vicine. Restituisce i vani [A, B, C, D] nello stesso ordine.
    def reveal_rects(openings, r, x0, x1, z0, z1, eps)
      openings.each_with_index.map do |(a, b, c, d), i|
        others = openings.each_with_index.reject { |_, j| j == i }.map(&:first)
        left = [r, a - x0 - eps].min
        right = [r, x1 - b - eps].min
        top = [r, z1 - d - eps].min
        bottom = door?([a, b, c, d], z0, eps) ? 0.0 : [r, c - z0 - eps].min
        others.each do |a2, b2, c2, d2|
          if c < d2 && d > c2 # affiancate
            left = [left, (a - b2) / 2.0 - eps].min if b2 <= a
            right = [right, (a2 - b) / 2.0 - eps].min if a2 >= b
          end
          next unless a < b2 && b > a2 # sovrapposte in pianta

          top = [top, (c2 - d) / 2.0 - eps].min if c2 >= d
          bottom = [bottom, (c - d2) / 2.0 - eps].min if d2 <= c && bottom.positive?
        end
        [a - [left, 0.0].max, b + [right, 0.0].max, c - [bottom, 0.0].max, d + [top, 0.0].max]
      end
    end

    # Volume netto atteso (box meno aperture), nelle stesse unità.
    def net_volume(x0, x1, y0, y1, z0, z1, openings)
      gross = (x1 - x0) * (y1 - y0) * (z1 - z0)
      gross - openings.sum { |a, b, c, d| (b - a) * (d - c) * (y1 - y0) }
    end
  end
end
