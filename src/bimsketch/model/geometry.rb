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

    # Taglia un'apertura passante in un muro parametrico (box locale
    # [0,L] x [0,T] x [0,H]). a..b = intervallo lungo x, c..d = lungo z.
    def cut_opening(wall, a, b, c, d)
      wall.make_unique if wall.respond_to?(:make_unique)
      ents = wall.definition.entities
      bb = wall.definition.bounds
      t = bb.max.y
      eps = TOL * 10

      # Rettangoli sulle due facce del muro, poi eliminati per creare il foro.
      [0, t].each do |y|
        f = ents.add_face([pt(a, y, c), pt(b, y, c), pt(b, y, d), pt(a, y, d)])
        f.erase! if f && f.valid?
      end

      # Facce di spalletta, orientate verso l'interno dell'apertura.
      reveals = [
        [[pt(a, 0, c), pt(a, t, c), pt(a, t, d), pt(a, 0, d)], X_AXIS],
        [[pt(b, 0, c), pt(b, 0, d), pt(b, t, d), pt(b, t, c)], X_AXIS.reverse],
        [[pt(a, 0, d), pt(a, t, d), pt(b, t, d), pt(b, 0, d)], Z_AXIS.reverse]
      ]
      reveals << [[pt(a, 0, c), pt(b, 0, c), pt(b, t, c), pt(a, t, c)], Z_AXIS] if c > eps
      reveals.each do |pts, normal|
        f = ents.add_face(pts)
        f.reverse! if f && f.normal.dot(normal) < 0
      end

      # Per le porte (c = 0) si elimina la porzione della faccia di base.
      if c <= eps
        ents.grep(Sketchup::Face).each do |f|
          next unless f.valid? && f.normal.z.abs > 0.99
          next unless f.vertices.all? do |v|
            p = v.position
            p.z.abs < eps && p.x > a - eps && p.x < b + eps
          end

          f.erase!
        end
      end
      stray = ents.grep(Sketchup::Edge).select { |e| e.valid? && e.faces.empty? }
      ents.erase_entities(stray) unless stray.empty?
      true
    end
  end
end
