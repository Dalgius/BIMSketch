# frozen_string_literal: true

module BIMSketch
  # Costruzione della geometria degli elementi BIM (unità interne SketchUp).
  # Ogni elemento è un gruppo con un sistema di riferimento locale:
  # x = asse dell'elemento, y = spessore/profondità, z = altezza.
  module Geometry
    TOL = 0.001.mm

    module_function

    def pt(x, y, z)
      Geom::Point3d.new(x, y, z)
    end

    # Estrude verso +z, di height, un poligono (con eventuali fori) giacente su z = 0.
    def prism(ents, outer, holes, height)
      face = ents.add_face(outer)
      return nil unless face

      holes.each do |hole|
        inner = ents.add_face(hole)
        inner.erase! if inner && inner.valid?
      end
      face.reverse! if face.normal.z > 0
      face.pushpull(-height)
      face
    end

    # Parallelepipedo [0,l] x [0,w] x [0,h].
    def box(ents, l, w, h)
      prism(ents, [pt(0, 0, 0), pt(l, 0, 0), pt(l, w, 0), pt(0, w, 0)], [], h)
    end

    # Telaio rettangolare nel piano xz (larghezza l, altezza h, profilo f),
    # estruso in y per la profondità d.
    def frame(ents, l, h, f, d)
      face = ents.add_face([pt(0, 0, 0), pt(l, 0, 0), pt(l, 0, h), pt(0, 0, h)])
      inner = ents.add_face([pt(f, 0, f), pt(l - f, 0, f), pt(l - f, 0, h - f), pt(f, 0, h - f)])
      inner.erase! if inner && inner.valid?
      face.reverse! if face.normal.y > 0
      face.pushpull(-d)
      face
    end

    # Crea un nuovo gruppo nel contesto attivo con la trasformazione (in
    # coordinate mondo) indicata; il blocco riceve le entità del gruppo.
    def create_group(model, transformation)
      group = model.active_entities.add_group
      yield group.entities
      transformation = model.edit_transform.inverse * transformation if model.active_path
      group.transformation = transformation
      group
    end

    # Trasformazione locale -> mondo con origine e asse x indicati (z verticale).
    def frame_transform(origin, xaxis)
      x = Geom::Vector3d.new(xaxis.x, xaxis.y, 0)
      x = X_AXIS.clone if x.length < TOL
      x.normalize!
      y = Z_AXIS * x
      Geom::Transformation.axes(origin, x, y, Z_AXIS)
    end

    # Fattori di scala di una trasformazione lungo gli assi locali.
    def scales(tr)
      [X_AXIS, Y_AXIS, Z_AXIS].map { |v| v.transform(tr).length.to_f }
    end

    # Ricava punti nel contesto di modifica attivo a partire da coordinate mondo.
    def to_active(model, point)
      return point unless model.active_path

      point.transform(model.edit_transform.inverse)
    end

    # Geometria di un muro parametrico nel suo sistema locale: impronta da
    # WallJoint.footprint (testate anche oblique, per i giunti a quartabuono)
    # alta height, con le aperture [a, b, c, d].
    # layers: fasce degli strati [[y0, y1, nome, materiale SketchUp], ...]:
    # ogni strato diventa un gruppo annidato con il suo materiale; senza
    # strati il muro è un unico solido.
    def build_wall(ents, length, thickness, height, ext, openings, layers: nil)
      if layers.nil? || layers.empty?
        build_wall_band(ents, length, thickness, 0.0, thickness, height, ext, openings)
        return true
      end
      layers.each_with_index do |(y0, y1, name, material), i|
        next if y1 - y0 < TOL * 10

        sub = ents.add_group
        build_wall_band(sub.entities, length, thickness, y0, y1, height, ext, openings)
        sub.name = name.to_s
        sub.material = material if material
        sub.set_attribute('BIMSketch', 'layer', i)
      end
      true
    end

    # Geometria di un solaio nel suo sistema locale: il contorno outline (e i
    # fori holes), poligoni [[x, y], ...], estruso da z = base per thickness.
    # layers: fasce degli strati [[z0, z1, nome, materiale SketchUp], ...]
    # misurate da base; ogni strato diventa un gruppo annidato.
    def build_slab(ents, outline, holes, base, thickness, layers: nil)
      at = ->(poly, z) { poly.map { |x, y| pt(x, y, z) } }
      if layers.nil? || layers.empty?
        raise 'impossibile costruire il solaio' unless prism(ents, at.call(outline, base),
                                                            holes.map { |h| at.call(h, base) }, thickness)

        return true
      end
      layers.each_with_index do |(z0, z1, name, material), i|
        next if z1 - z0 < TOL * 10

        sub = ents.add_group
        z = base + z0
        raise 'impossibile costruire uno strato del solaio' unless prism(sub.entities, at.call(outline, z),
                                                                        holes.map { |h| at.call(h, z) }, z1 - z0)

        sub.name = name.to_s
        sub.material = material if material
        sub.set_attribute('BIMSketch', 'layer', i)
      end
      true
    end

    # Una fascia y0..y1 del muro: il prospetto della faccia y = y0 (rientranze
    # per le porte, fori per le finestre) viene estruso fino a y = y1; poi i
    # vertici delle testate sulla faccia y1 vengono spostati per inclinarle.
    def build_wall_band(ents, length, thickness, y0, y1, height, ext, openings)
      be = WallJoint.band_ext(ext, thickness.to_f, y0.to_f, y1.to_f)
      fp = WallJoint.footprint(length.to_f, (y1 - y0).to_f, be)
      xs0 = fp[0][0]
      xe0 = fp[1][0]
      xe1 = fp[2][0]
      xs1 = fp[3][0]
      eps = TOL * 10
      outline = WallProfile.outline(xs0, xe0, 0.0, height.to_f, openings, eps).map { |x, z| pt(x, y0, z) }
      holes = WallProfile.holes(openings, 0.0, eps).map { |h| h.map { |x, z| pt(x, y0, z) } }
      face = ents.add_face(outline)
      raise 'impossibile costruire il prospetto del muro' unless face

      holes.each do |hole|
        inner = ents.add_face(hole)
        inner.erase! if inner && inner.valid?
      end
      face.reverse! if face.normal.y > 0
      face.pushpull(-(y1 - y0))

      verts = []
      vecs = []
      ents.grep(Sketchup::Edge).flat_map(&:vertices).uniq.each do |v|
        p = v.position
        next unless (p.y - y1).abs < eps

        if (p.x - xs0).abs < eps && (xs1 - xs0).abs > eps
          verts << v
          vecs << Geom::Vector3d.new(xs1 - xs0, 0, 0)
        elsif (p.x - xe0).abs < eps && (xe1 - xe0).abs > eps
          verts << v
          vecs << Geom::Vector3d.new(xe1 - xe0, 0, 0)
        end
      end
      ents.transform_by_vectors(verts, vecs) unless verts.empty?
      true
    end

    # Volume di un gruppo/componente nelle coordinate del suo contenitore:
    # quello di SketchUp se è un solido, altrimenti la somma dei sotto-gruppi
    # solidi (es. un muro a strati). -1 se non è calcolabile.
    def solid_volume(entity)
      v = entity.respond_to?(:volume) ? entity.volume : -1
      return v if v > 0

      ents = entity.definition.entities
      return -1 if ents.grep(Sketchup::Face).any?

      kids = ents.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
      return -1 if kids.empty?

      vols = kids.map { |k| solid_volume(k) }
      return -1 if vols.any? { |x| x <= 0 }

      vols.sum * scales(entity.transformation).reduce(:*)
    end
  end
end
