# frozen_string_literal: true

module BIMSketch
  module Tools
    # Strumento Porta/Finestra: si passa sopra un muro creato con BIMSketch e
    # si clicca per inserire l'apertura (il foro viene tagliato nel muro).
    class OpeningTool < BaseTool
      def initialize(kind)
        super()
        @kind = kind # 'door' o 'window'
      end

      def enableVCB?
        false
      end

      def onMouseMove(flags, x, y, view)
        @wall = nil
        @local_x = nil
        ph = view.pick_helper
        ph.do_pick(x, y)
        candidate = ph.best_picked
        if candidate && Builder.parametric_wall?(candidate)
          @ip.pick(view, x, y)
          if @ip.valid?
            @wall = candidate
            @local_x = to_wall_local(@ip.position).x
          end
        end
        super(flags, x, y, view) unless @wall
        update_preview(view)
        update_ui
        view.invalidate
      end

      def onLButtonDown(_flags, _x, _y, view)
        unless @wall
          UI.beep
          return
        end
        if rect.nil?
          UI.messagebox("L'apertura non entra nel muro o si sovrappone a un'altra apertura: " \
                        'verifica posizione e dimensioni nelle impostazioni.')
          return
        end
        wall = @wall
        local_x = @local_x
        label = door? ? 'Porta' : 'Finestra'
        run_operation("BIMSketch: #{label}") do
          Builder.opening(model, wall, @kind, local_x, width, height, sill, type_id: type['id'])
        end
        @wall = nil
        @preview = []
        view.invalidate
      end

      def draw(view)
        draw_preview(view)
      end

      # Tasto destro: scelta della tipologia (con le sue dimensioni predefinite).
      def getMenu(menu, *args)
        sub = menu.add_submenu(door? ? 'Tipologia porta' : 'Tipologia finestra')
        OpeningTypes.all(@kind).each do |t|
          dims = format('%d x %d cm', (t['width'] * 100).round, (t['height'] * 100).round)
          item = sub.add_item("#{t['name']} (#{dims})") do
            Settings.apply_opening_type(@kind, t['id'])
            update_ui
            Sketchup.active_model.active_view.invalidate
          end
          sub.set_validation_proc(item) { t['id'] == type['id'] ? MF_CHECKED : MF_UNCHECKED }
        end
        super
      end

      protected

      def door?
        @kind == 'door'
      end

      def type
        Settings.opening_type(@kind)
      end

      def width
        Settings.length(door? ? 'door_width' : 'window_width')
      end

      def height
        Settings.length(door? ? 'door_height' : 'window_height')
      end

      def sill
        door? ? 0 : Settings.length('window_sill')
      end

      def update_ui
        what = type['name']
        dims = "#{width.to_s} x #{height.to_s}"
        Sketchup.status_text = if @wall
                                 "#{what} #{dims}: clic per inserire nel muro."
                               else
                                 "#{what} #{dims}: passa sopra un muro BIMSketch. " \
                                   'Tasto destro: tipologia e impostazioni.'
                               end
      end

      # Trasformazione contesto attivo -> mondo.
      def context_tr
        model.active_path ? model.edit_transform : Geom::Transformation.new
      end

      def to_wall_local(world_point)
        world_point.transform((context_tr * @wall.transformation).inverse)
      end

      def rect
        return nil unless @wall && @local_x

        Builder.opening_rect(@wall, @local_x, width, height, sill)
      end

      def update_preview(_view)
        @preview = []
        r = rect
        return unless r

        a, b, c, d = r
        t = @wall.definition.bounds.max.y
        tr = context_tr * @wall.transformation
        @preview = [0, t].map do |y|
          [[a, y, c], [b, y, c], [b, y, d], [a, y, d]].map { |p| Geom::Point3d.new(p).transform(tr) }
        end
      end
    end

    # Strumento Sposta apertura: clic su una porta o finestra, poi la si fa
    # scorrere lungo il suo muro e si clicca per posarla (oppure si digita
    # la distanza dello spostamento). Il foro nel muro viene ritagliato.
    class MoveOpeningTool < BaseTool
      def onMouseMove(flags, x, y, view)
        if @opening
          @ip.pick(view, x, y)
          update_preview(view)
        else
          @hover = pick_opening(view, x, y)
          super unless @hover
        end
        update_ui
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        if @opening
          place(@candidate ? @candidate[0] : nil)
        else
          start(pick_opening(view, x, y), view, x, y)
        end
        update_ui
        view.invalidate
      end

      # Distanza digitata: spostamento lungo il muro nel verso del mouse.
      def onUserText(text, view)
        return unless @opening

        d = parse_length(text)
        return unless d

        sx = Geometry.scales(@wall.transformation)[0]
        sign = @candidate && @candidate[0] < @rect[0] ? -1 : 1
        place(@rect[0] + sign * d.to_f / sx)
        update_ui
        view.invalidate
      end

      def draw(view)
        if @hover && !@opening
          view.drawing_color = PREVIEW_COLOR
          view.line_width = 3
          box = @hover.bounds
          view.draw(GL_LINES, [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4],
                               [0, 4], [1, 5], [2, 6], [3, 7]].flatten.map { |i| box.corner(i).transform(context_tr) })
        end
        super
      end

      protected

      def reset_tool
        super
        @opening = nil
        @wall = nil
        @rect = nil
        @candidate = nil
        @hover = nil
      end

      def update_ui
        Sketchup.status_text = if @opening
                                 'Sposta apertura: muovi lungo il muro e clic per posarla, oppure digita ' \
                                   'la distanza. Esc per annullare.'
                               else
                                 'Sposta apertura: clic su una porta o finestra BIMSketch.'
                               end
        Sketchup.vcb_label = 'Distanza'
        Sketchup.vcb_value = if @candidate
                               ((@candidate[0] - @rect[0]).abs * Geometry.scales(@wall.transformation)[0]).to_l.to_s
                             else
                               ''
                             end
      end

      def context_tr
        model.active_path ? model.edit_transform : Geom::Transformation.new
      end

      def pick_opening(view, x, y)
        ph = view.pick_helper
        ph.do_pick(x, y)
        (0...ph.count).each do |i|
          ph.path_at(i).to_a.each do |e|
            next unless BimData.element?(e) && %w[door window].include?(BimData.type_key(e))
            return e if Builder.opening_position(model, e)
          end
        end
        nil
      end

      def start(opening, view, x, y)
        return UI.beep unless opening

        pos = Builder.opening_position(model, opening)
        return UI.beep unless pos

        @opening = opening
        @wall = pos[:wall]
        @rect = pos[:rect]
        @ip.pick(view, x, y)
        @grab = @ip.valid? ? local_x(@ip.position) - @rect[0] : (@rect[1] - @rect[0]) / 2.0
        update_preview(view)
      end

      # Nuovo vano per il lato sinistro in a (coordinate locali del muro).
      def candidate_for(a)
        sx, _sy, sz = Geometry.scales(@wall.transformation)
        w = @rect[1] - @rect[0]
        Builder.opening_rect(@wall, a + w / 2.0, w * sx, (@rect[3] - @rect[2]) * sz, @rect[2] * sz, ignore: @rect)
      end

      def place(a)
        rect = a && candidate_for(a)
        unless rect
          UI.messagebox("L'apertura non entra in quella posizione o si sovrappone a un'altra apertura.")
          return
        end
        opening = @opening
        left = rect[0] * Geometry.scales(@wall.transformation)[0]
        ok = run_operation('BIMSketch: Sposta apertura') do
          Builder.move_opening(model, opening, left: left, strict: false)
        end
        UI.messagebox("L'apertura non è stata spostata: il muro è stato modificato a mano.") if ok == false
        reset_tool
      end

      def local_x(world_point)
        world_point.transform((context_tr * @wall.transformation).inverse).x
      end

      def update_preview(_view)
        @preview = []
        @candidate = nil
        return unless @opening && @ip.valid?

        @candidate = candidate_for(local_x(@ip.position) - @grab)
        return unless @candidate

        a, b, c, d = @candidate
        t = @wall.definition.bounds.max.y
        tr = context_tr * @wall.transformation
        @preview = [0, t].map do |y|
          [[a, y, c], [b, y, c], [b, y, d], [a, y, d]].map { |p| Geom::Point3d.new(p).transform(tr) }
        end
      end
    end
  end
end
