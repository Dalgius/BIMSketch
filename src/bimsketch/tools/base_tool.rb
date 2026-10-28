# frozen_string_literal: true

module BIMSketch
  module Tools
    # Funzionalità comuni degli strumenti di disegno: punti di input con
    # inferenza, proiezione sulla quota del livello, input dalla VCB.
    class BaseTool
      PREVIEW_COLOR = Sketchup::Color.new(30, 120, 220)

      def activate
        @ip = Sketchup::InputPoint.new
        @ref_ip = Sketchup::InputPoint.new
        @points = []
        @preview = []
        reset_tool
        update_ui
        Sketchup.active_model.active_view.invalidate
      end

      def deactivate(view)
        view.invalidate
      end

      def resume(view)
        update_ui
        view.invalidate
      end

      def onCancel(_reason, view)
        reset_tool
        update_ui
        view.invalidate
      end

      def enableVCB?
        true
      end

      def onMouseMove(_flags, x, y, view)
        if @points.empty?
          @ip.pick(view, x, y)
        else
          @ip.pick(view, x, y, @ref_ip)
        end
        view.tooltip = @ip.tooltip if @ip.valid?
        update_preview(view)
        view.invalidate
      end

      def onKeyDown(key, _repeat, _flags, view)
        return unless key == CONSTRAIN_MODIFIER_KEY

        if view.inference_locked?
          view.lock_inference
        elsif @ip.valid?
          @points.empty? ? view.lock_inference(@ip) : view.lock_inference(@ip, @ref_ip)
        end
      end

      def onKeyUp(key, _repeat, _flags, view)
        view.lock_inference if key == CONSTRAIN_MODIFIER_KEY && view.inference_locked?
      end

      def getMenu(menu, *_args)
        menu.add_item('Impostazioni elementi...') do
          Settings.edit
          Sketchup.active_model.active_view.invalidate
        end
        menu.add_item('Livelli...') { BIMSketch.panel.show_tab('levels') }
      end

      def draw(view)
        @ip.draw(view) if @ip.valid? && @ip.display?
        draw_preview(view)
      end

      def getExtents
        bb = Geom::BoundingBox.new
        @points.each { |p| bb.add(p) }
        @preview.each { |loop| loop.each { |p| bb.add(p) } }
        bb
      end

      protected

      def model
        Sketchup.active_model
      end

      def reset_tool
        @points = []
        @preview = []
      end

      def update_ui; end

      def update_preview(_view); end

      # Riferimento per l'inferenza (assi, parallele) nel punto indicato:
      # l'ultimo punto effettivamente usato, non la posizione del mouse, che
      # dopo una misura digitata è altrove.
      def reference_at(point)
        @ref_ip = Sketchup::InputPoint.new(point)
      end

      # Posizione corrente proiettata sulla quota z indicata.
      def projected(z)
        p = @ip.position
        Geom::Point3d.new(p.x, p.y, z)
      end

      def level_z
        Levels.current_elevation(model)
      end

      def level_label
        lvl = Levels.current(model)
        "Livello: #{lvl['name']} (#{format('%.2f', lvl['elevation'])} m)"
      end

      def draw_preview(view)
        return if @preview.empty?

        view.drawing_color = PREVIEW_COLOR
        view.line_width = 2
        view.line_stipple = ''
        @preview.each { |loop| view.draw(GL_LINE_LOOP, loop) if loop.size > 1 }
      end

      # Contorno di un parallelepipedo (8 vertici) come anelli di linee.
      def box_loops(tr, l, w, h)
        bottom = [[0, 0, 0], [l, 0, 0], [l, w, 0], [0, w, 0]].map { |c| Geom::Point3d.new(c).transform(tr) }
        top = [[0, 0, h], [l, 0, h], [l, w, h], [0, w, h]].map { |c| Geom::Point3d.new(c).transform(tr) }
        verticals = (0..3).map { |i| [bottom[i], top[i]] }
        [bottom, top] + verticals
      end

      def parse_length(text)
        text.to_l
      rescue ArgumentError
        UI.beep
        nil
      end

      def run_operation(name)
        model.start_operation(name, true)
        result = yield
        model.commit_operation
        result
      rescue StandardError => e
        model.abort_operation
        UI.messagebox("BIMSketch: #{e.message}")
        puts e.backtrace.join("\n")
        nil
      end
    end
  end
end
