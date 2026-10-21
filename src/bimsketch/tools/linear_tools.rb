# frozen_string_literal: true

module BIMSketch
  module Tools
    # Strumento Muro: clic su punto iniziale e finale, disegno a catena.
    # Digitando un valore nella VCB si fissa la lunghezza del segmento.
    class WallTool < BaseTool
      COLLINEAR_TOL = 0.9998 # ~1°

      def onLButtonDown(_flags, _x, _y, view)
        return unless @ip.valid?

        pt = projected(level_z)
        if @points.empty?
          @points << pt
          @ref_ip.copy!(@ip)
        else
          create_to(pt)
        end
        update_ui
        view.invalidate
      end

      def onLButtonDoubleClick(_flags, _x, _y, view)
        reset_tool
        update_ui
        view.invalidate
      end

      def onReturn(view)
        onLButtonDoubleClick(0, 0, 0, view)
      end

      def onUserText(text, view)
        return if @points.empty?

        len = parse_length(text)
        return unless len

        dir = projected(level_z) - @points.last
        return if dir.length < Geometry::TOL

        create_to(@points.last.offset(dir, len))
        update_ui
        view.invalidate
      end

      protected

      def reset_tool
        super
        @last = nil
      end

      def update_ui
        Sketchup.status_text = if @points.empty?
                                 "Muro: clic sul punto iniziale. #{level_label}. " \
                                   'Tasto destro: impostazioni.'
                               else
                                 'Muro: clic sul punto finale o digita la lunghezza. ' \
                                   'Doppio clic, Invio o Esc per terminare.'
                               end
        Sketchup.vcb_label = 'Lunghezza'
      end

      def thickness
        Settings.length('wall_thickness')
      end

      def height
        h = Settings.get('wall_height').to_f
        h > 0 ? h.mm : Levels.current_height(model)
      end

      def update_preview(_view)
        @preview = []
        return if @points.empty? || !@ip.valid?

        p1 = @points.last
        p2 = projected(level_z)
        dir = p2 - p1
        return if dir.length < Geometry::TOL

        align = Settings.get('wall_align')
        off = { 'left' => 0, 'right' => -thickness }.fetch(align, -thickness / 2.0)
        x = dir.normalize
        origin = p1.offset(Z_AXIS * x, off)
        tr = Geometry.frame_transform(origin, x)
        @preview = box_loops(tr, dir.length, thickness, height)
        Sketchup.vcb_value = dir.length.to_s
      end

      def create_to(pt)
        start = @points.last
        return if start.distance(pt) < Geometry::TOL

        t = thickness
        h = height
        align = Settings.get('wall_align')
        wall = run_operation('BIMSketch: Muro') do
          ext_start = 0
          if @last && @last[:group].valid? && align == 'center' && corner?(@last, start, pt)
            # Giunto d'angolo: si prolunga il muro precedente e si accorcia il nuovo.
            prev = @last
            prev[:group].erase!
            prev[:group] = Builder.wall(model, prev[:p1], prev[:p2], t, h, align,
                                        ext_start: prev[:ext_start], ext_end: t / 2.0)
            ext_start = -t / 2.0
          end
          group = Builder.wall(model, start, pt, t, h, align, ext_start: ext_start)
          @last = { group: group, p1: start, p2: pt, ext_start: ext_start } if group
          group
        end
        @points << pt if wall
        @ref_ip.copy!(@ip)
      end

      def corner?(last, start, pt)
        return false unless last[:p2].distance(start) < Geometry::TOL

        d1 = (last[:p2] - last[:p1]).normalize
        d2 = (pt - start).normalize
        d1.dot(d2).abs < COLLINEAR_TOL
      end
    end

    # Strumento Trave: due clic; l'estradosso è alla quota del livello
    # superiore (quota livello + altezza livello).
    class BeamTool < WallTool
      protected

      def update_ui
        Sketchup.status_text = if @points.empty?
                                 "Trave: clic sul punto iniziale. #{level_label}."
                               else
                                 'Trave: clic sul punto finale o digita la lunghezza. ' \
                                   'Doppio clic, Invio o Esc per terminare.'
                               end
        Sketchup.vcb_label = 'Lunghezza'
      end

      def top_z
        level_z + Levels.current_height(model)
      end

      def update_preview(_view)
        @preview = []
        return if @points.empty? || !@ip.valid?

        p1 = @points.last
        p2 = projected(level_z)
        dir = p2 - p1
        return if dir.length < Geometry::TOL

        w = Settings.length('beam_width')
        h = Settings.length('beam_height')
        x = dir.normalize
        origin = Geom::Point3d.new(p1.x, p1.y, top_z - h).offset(Z_AXIS * x, -w / 2.0)
        @preview = box_loops(Geometry.frame_transform(origin, x), dir.length, w, h)
        Sketchup.vcb_value = dir.length.to_s
      end

      def create_to(pt)
        start = @points.last
        return if start.distance(pt) < Geometry::TOL

        beam = run_operation('BIMSketch: Trave') do
          Builder.beam(model, start, pt, Settings.length('beam_width'),
                       Settings.length('beam_height'), top_z)
        end
        @points << pt if beam
        @ref_ip.copy!(@ip)
      end
    end

    # Strumento Solaio: clic sui vertici del contorno; si chiude cliccando
    # sul primo punto, con doppio clic o con Invio.
    class SlabTool < BaseTool
      CLOSE_PIXELS = 10

      def onLButtonDown(_flags, x, y, view)
        return unless @ip.valid?

        pt = projected(level_z)
        if @points.size >= 3 && near_first?(view, x, y)
          create
        else
          @points << pt unless @points.last && @points.last.distance(pt) < Geometry::TOL
          @ref_ip.copy!(@ip)
        end
        update_ui
        view.invalidate
      end

      def onLButtonDoubleClick(_flags, _x, _y, view)
        create if @points.size >= 3
        update_ui
        view.invalidate
      end

      def onReturn(view)
        onLButtonDoubleClick(0, 0, 0, view)
      end

      def onUserText(text, view)
        return if @points.empty?

        len = parse_length(text)
        return unless len

        dir = projected(level_z) - @points.last
        return if dir.length < Geometry::TOL

        @points << @points.last.offset(dir, len)
        update_ui
        view.invalidate
      end

      protected

      def update_ui
        Sketchup.status_text = if @points.empty?
                                 "Solaio: clic sul primo vertice del contorno. #{level_label} " \
                                   '(estradosso alla quota del livello).'
                               else
                                 "Solaio: #{@points.size} vertici. Clic sul primo punto, " \
                                   'doppio clic o Invio per chiudere.'
                               end
        Sketchup.vcb_label = 'Lunghezza'
      end

      def near_first?(view, x, y)
        sp = view.screen_coords(@points.first)
        Math.hypot(sp.x - x, sp.y - y) < CLOSE_PIXELS
      end

      def update_preview(_view)
        pts = @points.dup
        pts << projected(level_z) if @ip.valid? && !@points.empty?
        @preview = pts.size > 1 ? [pts] : []
      end

      def create
        pts = @points
        run_operation('BIMSketch: Solaio') do
          Builder.slab(model, pts, Settings.length('slab_thickness'), level_z)
        end
        reset_tool
      end
    end

    # Strumento Pilastro: un clic per posizionare il pilastro (centro).
    class ColumnTool < BaseTool
      def enableVCB?
        false
      end

      def onLButtonDown(_flags, _x, _y, view)
        return unless @ip.valid?

        center = projected(level_z)
        run_operation('BIMSketch: Pilastro') do
          Builder.column(model, center, Settings.length('column_width'),
                         Settings.length('column_depth'), Levels.current_height(model))
        end
        view.invalidate
      end

      protected

      def update_ui
        Sketchup.status_text = "Pilastro: clic per posizionare il centro. #{level_label}."
      end

      def update_preview(_view)
        @preview = []
        return unless @ip.valid?

        w = Settings.length('column_width')
        d = Settings.length('column_depth')
        c = projected(level_z)
        tr = Geom::Transformation.translation(Geom::Point3d.new(c.x - w / 2.0, c.y - d / 2.0, c.z))
        @preview = box_loops(tr, w, d, Levels.current_height(model))
      end
    end
  end
end
