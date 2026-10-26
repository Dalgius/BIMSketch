# frozen_string_literal: true

module BIMSketch
  # Tipologie di porte e finestre (modulo puro Ruby): dimensioni predefinite
  # (m), forma della geometria e dati IFC.
  #   style:     'swing' (anta piena a battente), 'sliding' (anta scorrevole),
  #              'glazed' (ante vetrate), 'sash' (finestra con ante), 'fixed'
  #   leaves:    numero di ante
  #   operation: IfcDoorTypeOperationEnum / IfcWindowTypePartitioningEnum
  module OpeningTypes
    TYPES = [
      { 'id' => 'D1', 'kind' => 'door', 'name' => 'Porta a battente', 'width' => 0.9, 'height' => 2.1,
        'sill' => 0.0, 'style' => 'swing', 'leaves' => 1, 'operation' => 'SINGLE_SWING_LEFT' },
      { 'id' => 'D2', 'kind' => 'door', 'name' => 'Porta a due ante', 'width' => 1.4, 'height' => 2.1,
        'sill' => 0.0, 'style' => 'swing', 'leaves' => 2, 'operation' => 'DOUBLE_DOOR_SINGLE_SWING' },
      { 'id' => 'D3', 'kind' => 'door', 'name' => 'Porta scorrevole', 'width' => 0.9, 'height' => 2.1,
        'sill' => 0.0, 'style' => 'sliding', 'leaves' => 1, 'operation' => 'SLIDING_TO_LEFT' },
      { 'id' => 'D4', 'kind' => 'door', 'name' => 'Portafinestra a due ante', 'width' => 1.4, 'height' => 2.4,
        'sill' => 0.0, 'style' => 'glazed', 'leaves' => 2, 'operation' => 'DOUBLE_DOOR_SINGLE_SWING' },
      { 'id' => 'W1', 'kind' => 'window', 'name' => "Finestra a un'anta", 'width' => 0.8, 'height' => 1.4,
        'sill' => 0.9, 'style' => 'sash', 'leaves' => 1, 'operation' => 'SINGLE_PANEL' },
      { 'id' => 'W2', 'kind' => 'window', 'name' => 'Finestra a due ante', 'width' => 1.2, 'height' => 1.4,
        'sill' => 0.9, 'style' => 'sash', 'leaves' => 2, 'operation' => 'DOUBLE_PANEL_VERTICAL' },
      { 'id' => 'W3', 'kind' => 'window', 'name' => 'Vasistas', 'width' => 0.8, 'height' => 0.6,
        'sill' => 1.5, 'style' => 'sash', 'leaves' => 1, 'operation' => 'SINGLE_PANEL' },
      { 'id' => 'W4', 'kind' => 'window', 'name' => 'Finestra fissa', 'width' => 1.0, 'height' => 1.0,
        'sill' => 1.0, 'style' => 'fixed', 'leaves' => 0, 'operation' => 'SINGLE_PANEL' }
    ].freeze

    DEFAULT = { 'door' => 'D1', 'window' => 'W2' }.freeze

    module_function

    def all(kind = nil)
      kind ? TYPES.select { |t| t['kind'] == kind } : TYPES
    end

    def find(id)
      TYPES.find { |t| t['id'] == id }
    end

    # Tipologia indicata, se è del tipo giusto; altrimenti quella predefinita.
    def for_kind(kind, id = nil)
      t = find(id.to_s)
      t && t['kind'] == kind ? t : find(DEFAULT[kind])
    end

    # Larghezza delle ante affiancate in un vano largo inner (stessa unità):
    # [[x0, x1], ...] con giunto gap tra un'anta e l'altra.
    def leaf_spans(inner, leaves, gap = 0.0)
      n = [leaves.to_i, 1].max
      w = (inner - gap * (n - 1)) / n.to_f
      (0...n).map { |i| [i * (w + gap), i * (w + gap) + w] }
    end
  end
end
