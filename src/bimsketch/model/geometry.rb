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
    # alta height, con le aperture [a, b, c, d]. Il prospetto della faccia
    # y = 0 (rientranze per le porte, fori per le finestre) viene estruso
    # fino a y = thickness; poi i vertici delle testate sulla faccia opposta
    # vengono spostati per inclinare le testate.
    def build_wall(ents, length, thickness, height, ext, openings)
      fp = WallJoint.footprint(length.to_f, thickness.to_f, ext)
      xs0 = fp[0][0]
      xe0 = fp[1][0]
      xe1 = fp[2][0]
      xs1 = fp[3][0]
      eps = TOL * 10
      outline = WallProfile.outline(xs0, xe0, 0.0, height.to_f, openings, eps).map { |x, z| pt(x, 0, z) }
      holes = WallProfile.holes(openings, 0.0, eps).map { |h| h.map { |x, z| pt(x, 0, z) } }
      face = ents.add_face(outline)
      raise 'impossibile costruire il prospetto del muro' unless face

      holes.each do |hole|
        inner = ents.add_face(hole)
        inner.erase! if inner && inner.valid?
      end
      face.reverse! if face.normal.y > 0
      face.pushpull(-thickness)

      verts = []
      vecs = []
      ents.grep(Sketchup::Edge).flat_map(&:vertices).uniq.each do |v|
        p = v.position
        next unless (p.y - thickness).abs < eps

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
  end
end
