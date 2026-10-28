# frozen_string_literal: true

module BIMSketch
  module Tools
    # Strumento Foro nel solaio: due clic su un solaio per i vertici opposti
    # del rettangolo (allineato agli assi), oppure dopo il primo clic si
    # digitano le dimensioni "larghezza;profondità".
    class SlabHoleTool < BaseTool
      def onMouseMove(flags, x, y, view)
        super(flags, x, y, view)
        @hover = @slab ? nil : Builder.slab_under_ray(model, view.pickray(x, y))
        update_preview(view)
        update_ui
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        if @slab
          create(@corner)
        else
          hit = Builder.slab_under_ray(model, view.pickray(x, y))
          return UI.beep unless hit

          @slab = hit[0]
          @top = hit[1].z
          @start = on_slab(@ip.valid? ? @ip.position : hit[1])
          @points = [@start]
          reference_at(@start)
        end
        update_ui
        view.invalidate
      end

      def onUserText(text, view)
        return unless @slab

        parts = text.split(/[;x×]/i).map { |t| parse_length(t.strip) }
        return UI.beep unless parts.size == 2 && parts.all?

        cur = @corner || @start
        sx = cur.x < @start.x ? -1 : 1
        sy = cur.y < @start.y ? -1 : 1
        create(Geom::Point3d.new(@start.x + sx * parts[0], @start.y + sy * parts[1], @top))
        view.invalidate
      end

      def enableVCB?
        !@slab.nil?
      end

      protected

      def reset_tool
        super
        @slab = nil
        @start = nil
        @corner = nil
        @hover = nil
      end

      def on_slab(point)
        Geom::Point3d.new(point.x, point.y, @top)
      end

      def rect(p, q)
        [p, Geom::Point3d.new(q.x, p.y, @top), q, Geom::Point3d.new(p.x, q.y, @top)]
      end

      def update_ui
        Sketchup.status_text = if @slab
                                 'Foro nel solaio: clic sul vertice opposto o digita larghezza;profondità. ' \
                                   'Esc per annullare.'
                               else
                                 'Foro nel solaio: clic sul primo vertice del foro, sopra un solaio BIMSketch.'
                               end
        Sketchup.vcb_label = 'Dimensioni'
      end

      def update_preview(_view)
        @preview = []
        if @slab && @ip.valid?
          @corner = on_slab(@ip.position)
          @preview = [rect(@start, @corner)]
          Sketchup.vcb_value = "#{(@corner.x - @start.x).abs.to_l};#{(@corner.y - @start.y).abs.to_l}"
        elsif @hover
          @preview = [[@hover[0].bounds.corner(4), @hover[0].bounds.corner(5), @hover[0].bounds.corner(7),
                       @hover[0].bounds.corner(6)]]
        end
      end

      def create(corner)
        return UI.beep unless corner && (corner.x - @start.x).abs > 1.mm && (corner.y - @start.y).abs > 1.mm

        slab = @slab
        pts = rect(@start, corner)
        result = run_operation('BIMSketch: Foro nel solaio') { Builder.add_slab_hole(model, slab, pts) }
        message = {
          outside: 'Il foro deve stare dentro il solaio, senza toccarne il bordo.',
          overlap: 'Il foro si sovrappone a un altro foro del solaio.',
          modified: 'Il solaio è stato modificato a mano: non è possibile ricostruirlo con il foro.'
        }[result]
        UI.messagebox(message) if message
        reset_tool
      end
    end

    # Strumento Scala: clic sul centro del primo gradino, poi nella direzione
    # di salita. La scala supera l'altezza del livello corrente con alzate e
    # pedate calcolate (regola di Blondel) e apre il foro nel solaio superiore.
    class StairTool < BaseTool
      def enableVCB?
        false
      end

      def onLButtonDown(_flags, _x, _y, view)
        return unless @ip.valid?

        pt = projected(level_z)
        if @points.empty?
          @points << pt
          reference_at(pt)
        else
          create(pt)
        end
        update_ui
        view.invalidate
      end

      protected

      def width
        Settings.length('stair_width')
      end

      def calc
        StairCalc.compute(Levels.current_height(model).to_m, max_riser: Settings.length('stair_riser').to_m)
      end

      def update_ui
        c = calc
        info = format('%d alzate da %.1f cm, pedata %.1f cm, lunghezza %.2f m', c[:risers], c[:riser] * 100,
                      c[:tread] * 100, c[:run]).tr('.', ',')
        Sketchup.status_text = if @points.empty?
                                 "Scala (#{info}): clic sul centro del primo gradino. #{level_label}."
                               else
                                 "Scala (#{info}): clic nella direzione di salita. Esc per annullare."
                               end
      end

      def update_preview(_view)
        @preview = []
        return if @points.empty? || !@ip.valid?

        start = @points.first
        dir = projected(level_z) - start
        return if dir.length < Geometry::TOL

        x = dir.normalize
        origin = start.offset(Z_AXIS * x, -width / 2.0)
        @preview = box_loops(Geometry.frame_transform(origin, x), calc[:run].m, width, Levels.current_height(model))
      end

      def create(pt)
        start = @points.first
        result = run_operation('BIMSketch: Scala') do
          Builder.stair(model, start, pt, width, Levels.current_height(model),
                        max_riser: Settings.length('stair_riser'))
        end
        reset_tool
        return unless result

        message = {
          outside: 'il foro uscirebbe dal solaio o ne toccherebbe il bordo',
          overlap: 'il foro si sovrapporrebbe a un altro foro',
          modified: 'il solaio è stato modificato a mano'
        }[result[:hole]]
        UI.messagebox("Scala creata, ma il foro nel solaio superiore non è stato aperto: #{message}.") if message
      end
    end
  end
end
