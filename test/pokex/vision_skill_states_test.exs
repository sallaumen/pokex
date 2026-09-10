defmodule Pokex.VisionSkillStatesTest do
  use ExUnit.Case, async: true
  alias Pokex.Vision
  alias Pokex.Vision.Frame

  describe "skill_states/2" do
    test "a colourful/bright slot reads :ready, a dark grey slot reads :cooldown" do
      # slots: yellow (ready), dark grey (cooldown), pink (ready), dark grey (cooldown)
      frame = bar([{200, 200, 0}, {30, 30, 30}, {210, 40, 160}, {25, 25, 25}], 3)
      assert Vision.skill_states(frame, count: 4) == [:ready, :cooldown, :ready, :cooldown]
    end

    test "a DARK but colourful icon still reads :ready (saturation, not brightness)" do
      # dark green: dim (brightness 90) but saturated (90 >= 40) → ready.
      frame = bar([{0, 90, 0}, {30, 30, 30}], 2)
      assert Vision.skill_states(frame, count: 2) == [:ready, :cooldown]
    end

    # A COR ENGANA E O NÚMERO NÃO. O ícone oliva continua saturado embaixo do
    # cooldown, e o anti-aliasing do número branco por cima ainda mint pixels
    # vivos: a tecla 3 desta barra real mede saturação 32 e vivo 22 com um "12"
    # escrito nela. Quem desempata é o glifo, lido como glifo.
    test "the countdown number over a COLOURED icon reads :cooldown" do
      frame = real("tres_contando_ontem.raw")

      slots = Vision.skill_slots(frame, count: 9, min_saturation: 25, min_vivid_pct: 7)
      contando = Enum.at(slots, 2)

      # os testes de cor PASSAM (é essa a armadilha) — o dígito é que salva
      assert contando.saturation >= 25
      assert contando.vivid_pct >= 7
      assert contando.counting?
      assert contando.state == :cooldown
    end

    # …e o mesmo quadro prova o outro lado: a tecla 1 é um ícone de ARTE BRANCA
    # (5% de branco puro, mais que o "12" da vizinha põe) sem número nenhum. Ela
    # está PRONTA, e o veto de branco — aposentado em 09/09 — a lia como fria.
    test "white icon art with no number stays :ready" do
      frame = real("tres_contando_ontem.raw")

      [pronta | _] = Vision.skill_slots(frame, count: 9, min_saturation: 25, min_vivid_pct: 7)

      assert pronta.white_pct >= 4
      refute pronta.counting?
      assert pronta.state == :ready
    end

    test "the BIG white countdown ('17.6', under 20s) never fakes :ready — colour only" do
      # Under ~20s the game renders the countdown huge with decimals: enough WHITE pixels
      # to lift the slot's average brightness way up (here to ~136). White is colourless —
      # the old brightness-only branch read this as ready and pulled fish with every
      # kill-skill still on cooldown (Lucas, 2026-07-10). Saturation and vivid stay ~0 →
      # :cooldown.
      rgba =
        :binary.copy(<<40, 45, 40, 255>>, 55) <> :binary.copy(<<245, 245, 245, 255>>, 45)

      frame = %Frame{width: 100, height: 1, rgba: rgba}
      [slot] = Vision.skill_slots(frame, count: 1, min_saturation: 25, min_vivid_pct: 7)

      assert slot.brightness >= 90
      assert slot.state == :cooldown
    end

    test "a mostly-dark icon with a few VIVID pixels reads :ready (the green skill-3 case)" do
      # 9 near-black px + 1 vivid green px in one slot: avg brightness 29 and avg saturation 16
      # are BOTH below 90/25 (the old average test misread this as cooldown forever), but 10%
      # of the pixels are strongly coloured → :ready via vivid_pct.
      rgba = :binary.copy(<<10, 10, 10, 255>>, 9) <> <<40, 200, 40, 255>>
      frame = %Frame{width: 10, height: 1, rgba: rgba}

      states =
        Vision.skill_slots(frame,
          count: 1,
          min_saturation: 25,
          min_vivid_pct: 6
        )
        |> Enum.map(& &1.state)

      assert states == [:ready]
    end

    test "a greyed cooldown icon with a white number stays :cooldown (no vivid pixels)" do
      # a darkened greyish icon (desaturated) + one white countdown px: nothing is strongly
      # coloured (grey/white are colourless), avg brightness stays low → :cooldown.
      rgba = :binary.copy(<<40, 45, 40, 255>>, 9) <> <<240, 240, 240, 255>>
      frame = %Frame{width: 10, height: 1, rgba: rgba}

      states =
        Vision.skill_slots(frame,
          count: 1,
          min_saturation: 25,
          min_vivid_pct: 6
        )
        |> Enum.map(& &1.state)

      assert states == [:cooldown]
    end

    test "a cooldown retaining exactly 6% vivid pixels stays :cooldown" do
      # Reproduces the measured slot 5 from the real six-skill screenshot: the darkened
      # icon retains 6% coloured pixels and the white countdown adds brightness, but it
      # must stay below the new 7% vivid floor.
      rgba =
        :binary.copy(<<40, 45, 40, 255>>, 88) <>
          :binary.copy(<<40, 100, 40, 255>>, 6) <>
          :binary.copy(<<240, 240, 240, 255>>, 6)

      frame = %Frame{width: 100, height: 1, rgba: rgba}

      assert Vision.skill_states(frame,
               count: 1,
               min_saturation: 25,
               min_vivid_pct: 7
             ) == [:cooldown]
    end

    test "clamps the slot count to the frame width" do
      frame = bar([{200, 200, 0}, {200, 200, 0}], 1)
      assert length(Vision.skill_states(frame, count: 50)) == 2
    end
  end

  describe "skill_slots/2 with per-slot READY references (calibrated match)" do
    # Lucas's pink-with-white icon: its READY art carries >4% pure white, so the white
    # override read it permanently :cooldown. Against its own reference it must read :ready.
    @pink_ready :binary.copy(<<230, 120, 190, 255>>, 90) <>
                  :binary.copy(<<255, 255, 255, 255>>, 10)

    test "an icon matching its own reference reads :ready — even with lots of white art" do
      frame = %Frame{width: 100, height: 1, rgba: @pink_ready}
      # the reference: this exact icon's non-white signature (as calibration captures it)
      [%{signature: ref}] = Vision.skill_slots(frame, count: 1)

      [slot] = Vision.skill_slots(frame, count: 1, refs: [ref], max_distance: 60)
      assert slot.white_pct >= 4
      assert slot.distance <= 10
      assert slot.state == :ready
    end

    test "the darkened (overlay) icon reads :cooldown by distance — number excluded" do
      ready = %Frame{width: 100, height: 1, rgba: @pink_ready}
      [%{signature: ref}] = Vision.skill_slots(ready, count: 1)

      # cooldown: the overlay halves the icon's colour; a BIG white countdown covers 30%.
      # The white glyph is excluded from the signature, so what remains is the darkened
      # pink — far from the ready reference.
      cooling =
        :binary.copy(<<115, 60, 95, 255>>, 70) <> :binary.copy(<<255, 255, 255, 255>>, 30)

      frame = %Frame{width: 100, height: 1, rgba: cooling}
      [slot] = Vision.skill_slots(frame, count: 1, refs: [ref], max_distance: 60)

      assert slot.distance > 60
      assert slot.state == :cooldown
    end

    test "the dark REPLACEMENT panel reads :cooldown under the DEFAULT ceiling" do
      # Measured live (2026-07-20): PokeTibia's cooldown REPLACES the icon with a dark panel +
      # countdown number — it does not darken the art in place. Icons whose ready art is a
      # small glyph on black average out DARK (slot 3's ref measured {46, 75, 40}), so the
      # dark panel ({24, 35, 25}) sits only ~48 away — the old 60 ceiling read slots 3/6/8
      # falsely :ready mid-cooldown, while a TRUE ready match measures 0-1 (static art,
      # deterministic capture). The default ceiling must split ~1 from ~44 (the closest
      # cooldown measured: a red "16" glyph pulling the average toward a green ref).
      panel = :binary.copy(<<24, 35, 25, 255>>, 90) <> :binary.copy(<<255, 255, 255, 255>>, 10)
      frame = %Frame{width: 100, height: 1, rgba: panel}

      [slot] = Vision.skill_slots(frame, count: 1, refs: [{46, 75, 40}])

      assert slot.distance in 40..60
      assert slot.state == :cooldown
    end

    test "a true ready match stays :ready under the DEFAULT ceiling" do
      frame = %Frame{width: 100, height: 1, rgba: @pink_ready}
      [%{signature: ref}] = Vision.skill_slots(frame, count: 1)

      [slot] = Vision.skill_slots(frame, count: 1, refs: [ref])
      assert slot.state == :ready
    end

    test "slots without a reference fall back to the threshold rules" do
      # two slots, refs only for the first: slot 2 (colourful, no ref) uses the colour test
      rgba = :binary.copy(<<230, 120, 190, 255>>, 50) <> :binary.copy(<<200, 200, 0, 255>>, 50)
      frame = %Frame{width: 100, height: 1, rgba: rgba}
      [%{signature: ref}, _] = Vision.skill_slots(frame, count: 2)

      states =
        frame
        |> Vision.skill_slots(count: 2, refs: [ref, nil], max_distance: 60)
        |> Enum.map(& &1.state)

      assert states == [:ready, :ready]
    end
  end

  describe "skill_slots/2 (detailed, for the diagnostic + tuning)" do
    test "reports brightness, saturation, vivid_pct and state per slot" do
      [ready, cooldown] = Vision.skill_slots(bar([{200, 200, 0}, {20, 20, 20}], 2), count: 2)

      assert ready.state == :ready
      assert ready.brightness == 200
      assert ready.saturation == 200
      assert ready.vivid_pct == 100
      assert cooldown.state == :cooldown
      assert cooldown.brightness == 20
      assert cooldown.saturation == 0
      assert cooldown.vivid_pct == 0
    end

    test "thresholds are tunable" do
      # force everything to :cooldown with impossible thresholds (both colour paths)
      states =
        bar([{200, 200, 0}, {20, 20, 20}], 2)
        |> Vision.skill_slots(
          count: 2,
          min_saturation: 999,
          min_vivid_pct: 999
        )
        |> Enum.map(& &1.state)

      assert states == [:cooldown, :cooldown]
    end
  end

  # O PORTÃO É O RÓTULO DA TECLA. Em 02/09 a barra recém-calibrada do Venusaur
  # (recorte justo e correto) foi recusada em TODO tique do dia porque o portão
  # antigo pedia 10% de pixels quase-pretos e ela tinha 9,6% — o "escuro" era a
  # parte escura dos ícones, não uma moldura. O jogo desenha o número da tecla
  # embaixo de cada slot, pronta ou fria: é isso que diz "isto é a barra".
  describe "skill_bar_frame?/2" do
    @fixtures "test/fixtures/skill_bar"

    defp real(name) do
      {:ok, frame} = Frame.from_file(Path.join(@fixtures, name))
      frame
    end

    # `count` slots de `slot_w` px por `h` linhas; `paint.(slot, x, y)` dá a cor
    # do pixel (x, y relativos ao slot).
    defp bar_2d(count, slot_w, h, paint) do
      rgba =
        for y <- 0..(h - 1), slot <- 0..(count - 1), x <- 0..(slot_w - 1), into: <<>> do
          {r, g, b} = paint.(slot, x, y)
          <<r, g, b, 255>>
        end

      %Frame{width: count * slot_w, height: h, rgba: rgba}
    end

    # Um glifo da fonte do jogo: 2 px de largura por 6 de altura, branco, sobre
    # o fundo escuro do slot — o rótulo "1".."9".
    defp glyph?(x, y), do: x in 8..9 and y in 2..7
    @dark {20, 20, 20}
    @white {240, 240, 240}

    test "the tight Venusaur crop and the three August bars pass" do
      for name <-
            ~w(venusaur_recorte_justo.raw manha.raw quatro_contando.raw tres_contando_ontem.raw) do
        assert Vision.skill_bar_frame?(real(name), 9), name
      end
    end

    # THE ROUND-ICON BAR (Torterra, 8 skills, 2026-09-06). He tried twice and the
    # page refused: "o leitor só encontra o número da tecla em 1 de 8 slots".
    # Measured on his own capture: all eight digits ARE found, all the right
    # size, all on the same line — what failed was the black outline. This
    # client draws the label over the ART of a ROUND icon (cream, gold, tan),
    # and the outline blends with it: the ratios read 0.20 to 0.83 against a
    # 0.70 floor, because `dark?` demanded near-black (60).
    test "the round-icon bar, the label drawn over bright art" do
      assert Vision.skill_bar_frame?(real("icone_redondo_8.raw"), 8)
    end

    # …and the looser outline must not turn his LABELS into countdowns: every
    # skill was ready in this capture, and a label read as a count would make
    # the hunt skip a key that is up. Measured, not assumed.
    test "the round-icon labels are not read as cooldowns" do
      assert real("icone_redondo_8.raw") |> Pokex.Vision.SkillDigits.counting(8) |> Enum.empty?()
    end

    test "a bright panel and a piece of world in place of the bar do not pass" do
      refute Vision.skill_bar_frame?(real("nao_barra_painel_claro.raw"), 9)
      refute Vision.skill_bar_frame?(real("nao_barra_mundo.raw"), 9)
    end

    test "the label on every slot is the bar; on fewer than two thirds of them, it is not" do
      todos = bar_2d(9, 20, 10, fn _slot, x, y -> if glyph?(x, y), do: @white, else: @dark end)

      seis =
        bar_2d(9, 20, 10, fn slot, x, y ->
          if slot < 6 and glyph?(x, y), do: @white, else: @dark
        end)

      cinco =
        bar_2d(9, 20, 10, fn slot, x, y ->
          if slot < 5 and glyph?(x, y), do: @white, else: @dark
        end)

      assert Vision.skill_bar_frame?(todos, 9)
      assert Vision.skill_bar_frame?(seis, 9)
      refute Vision.skill_bar_frame?(cinco, 9)
    end

    test "dark colour and live icons WITHOUT a label are not enough: the old gate accepted that" do
      chrome =
        bar_2d(9, 20, 10, fn _slot, x, _y -> if x < 4, do: {10, 10, 10}, else: {40, 180, 80} end)

      branco = bar_2d(9, 20, 10, fn _slot, _x, _y -> @white end)
      cinza = bar_2d(9, 20, 10, fn _slot, _x, _y -> {120, 120, 120} end)

      refute Vision.skill_bar_frame?(chrome, 9)
      refute Vision.skill_bar_frame?(branco, 9)
      refute Vision.skill_bar_frame?(cinza, 9)
    end
  end

  # One-row frame: each slot is `slot_w` px of a solid colour, left→right.
  defp bar(colors, slot_w) do
    rgba = for {r, g, b} <- colors, into: <<>>, do: :binary.copy(<<r, g, b, 255>>, slot_w)
    %Frame{width: length(colors) * slot_w, height: 1, rgba: rgba}
  end
end
