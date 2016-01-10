require! {
  'chai': {assert}

  './pai': Pai
  './decomp': {decompTenpai, decompAgari}
  './split-wall': splitWall
  './util': {OTHER_PLAYERS}

  './kyoku-player-hidden': PlayerHidden
  './kyoku-player-hidden-mock': PlayerHiddenMock
}

# GLOBAL TODO:
# - explain doraHyouji piggybacking
# - more watertight `init` checks
# - assertion messages even though source is pretty natural language
# - fix doc of all events
# - event conversion and serialization


export Event = {}

# 2 categories of event:
# master-initiated:
# - construct then apply on master (by game logic)
# - send partial info to replicates
# - reconstruct then apply on replicates
# replicate-initiated:
# - construct on replicate-me (by player decision)
# - send constructor args to master
# - construct then apply on master (`doraHyouji` might be tagged on)
# - send full info to replicates
# - reconstruct then apply on replicates
#
# Notice that "constructor args" is also a minimal set of parameters that
# sufficiently determines the event (at current kyoku state)
#
# Data fields for each event are described in the following manner:
# common:
#   "minimal": args used to construct
#   "private": cached values
# master-initiated:
#   "partial": sent to replicates (does NOT include "minimal")
# replicate-initiated:
#   "full": sent to replicates (includes "minimal")


Event.deal = class Deal # {{{
  # master-initiated
  # minimal:
  #   wall: ?[136]Pai -- defaults to randomly shuffled
  # partial:
  #   haipai: [13]Pai -- each player receives only his own
  #   initDoraHyouji: [1]Pai
  # private:
  #   wallParts: {haipai, piipai, rinshan, doraHyouji, uraDoraHyouji}
  #   initDoraHyouji

  (kyoku, {@wall}) -> with kyoku
    assert not ..isReplicate
    @type = \deal
    @seq = 0
    @wall ?= Pai.shuffleAll ..rulevar.dora.akahai
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \deal
    assert.equal ..seq, 0
    assert.equal ..phase, \begin
    if not ..isReplicate
      assert.lengthOf @wall, 136
      @wallParts = splitWall @wall
      @initDoraHyouji = [@wallParts.doraHyouji.0]
    else
      assert.lengthOf @haipai, 13
      assert.lengthOf @initDoraHyouji, 1
    return this

  apply: !-> with kyoku = @kyoku
    if not ..isReplicate
      ..wallParts = {haipai} = @wallParts
      ..playerHidden = for p til 4
        new PlayerHidden haipai[(4 - ..chancha + p) % 4]
    else
      ..wallParts = piipai: [] rinshan: [] doraHyouji: [], uraDoraHyouji: []
      ..playerHidden = for p til 4
        if p == ..me then new PlayerHidden @haipai
        else new PlayerHiddenMock
    ..playerPublic = for p til 4
      new PlayerPublic (4 - ..chancha + p)%4
    .._addDoraHyouji @initDoraHyouji

    ..phase = \preTsumo
# }}}

Event.tsumo = class Tsumo # {{{
  # master-initiated
  # minimal: (null)
  # partial:
  #	  pai: ?Pai -- for current player only

  (kyoku) -> with kyoku
    assert not ..isReplicate
    assert ..nTsumoLeft > 0
    @type = \tsumo
    @seq = ..seq
    if @rinshan
      @pai = ..wallParts.rinshan[*-1]
    else
      @pai = ..wallParts.piipai[*-1]
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \tsumo
    assert.equal ..phase, \preTsumo
    assert ..nTsumoLeft > 0
    return this

  apply: !-> with kyoku = @kyoku
    if not ..isReplicate
      if ..rinshan
        ..wallParts.rinshan.pop!
      else
        ..wallParts.piipai.pop!
    ..nPiipaiLeft--
    ..playerHidden[..currPlayer].tsumo @pai
    # NOTE: above is correct -- rinshan tsumo also discards last piipai,
    # which is reflected in `nTsumoLeft`

    ..currPai = @pai # NOTE: null on replicate-others -- this is okay
    ..phase = \postTsumo
# }}}

Event.dahai = class Dahai # {{{
  # replicate-initiated
  # minimal:
  #   pai: Pai
  #   tsumokiri: ?Boolean
  #   riichi: Boolean
  # full:
  #   newDoraHyouji: ?[]Pai

  (kyoku, {@pai = null, @tsumokiri = false, @riichi = false}) -> with kyoku
    @type = \dahai
    @seq = ..seq
    if ..isReplicate
      assert.equal ..currPlayer, ..me,
        "cannot construct for others on replicate instance"
    # constructor shortcut: null `pai` implies tsumokiri
    # by definition: `pai = tsumohai`
    if !@pai? or @tsumokiri
      @pai = ..playerHidden[..currPlayer].tsumohai
      assert.isNotNull @pai, "tsumokiri requires tsumohai"
      @tsumokiri = true
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \dahai
    assert ..phase in <[postTsumo postChiPon]>#
    PP = ..playerPublic[..currPlayer]
    PH = ..playerHidden[..currPlayer]

    assert.isNotNull @pai
    pai = @pai

    if PP.riichi.accepted
      assert.isTrue @tsumokiri, "can only tsumokiri after riichi"
      assert.isFalse @riichi, "can only riichi once"

    if ..phase == \postChiPon and ..rulevar.banKuikae?
      assert not ..isKuikae(PP.fuuro[*-1], pai), "kuikae banned by rule"

    # master: try reveal doraHyouji
    if not ..isReplicate
      @newDoraHyouji ?= ..getNewDoraHyouji this

    if PH not instanceof PlayerHidden then return this
    with (if @tsumokiri then PH.canTsumokiri! else PH.canDahai pai)
      assert ..valid, ..reason
    if @riichi
      assert.isTrue PP.menzen, "can only riichi when menzen"
      n = ..nTsumoLeft
      m = ..rulevar.riichi.minPiipaiLeft
      assert n >= m, "need at least #m piipai left (only #n now)"
      if @tsumokiri
        decomp = PH.tenpaiDecomp # maintained by PlayerHidden
      else
        decomp = PH.decompTenpaiWithout pai # calculated on demand
      assert decomp?.wait?.length > 0, "not tenpai if dahai is [#pai]"

    return this

  apply: !-> with kyoku = @kyoku
    PP = ..playerPublic[..currPlayer]
    PH = ..playerHidden[..currPlayer]

    if @riichi
      PP.riichi.declared = true
      if ..isTrueFirstTsumo ..currPlayer then PP.riichi.double = true
    if @tsumokiri
      PP.tsumokiri @pai
      PH.tsumokiri!
    else
      PP.dahai @pai
      PH.dahai @pai

    .._addDoraHyouji @newDoraHyouji

    ..rinshan = false
    ..currPai = @pai
    ..phase = \postDahai
# }}}

Event.ankan = class Ankan # {{{
  # replicate-initiated
  # minimal:
  #   pai: Pai
  # full:
  #   newDoraHyouji: ?[]Pai
  # private:
  #   fuuro

  (kyoku, {@pai}) -> with kyoku
    @type = \ankan
    @seq = ..seq
    if ..isReplicate
      assert.equal ..currPlayer, ..me,
        "cannot construct for others on replicate instance"
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \ankan
    assert.equal ..phase, \postTsumo
    PP = ..playerPublic[..currPlayer]
    PH = ..playerHidden[..currPlayer]

    assert ..nPiiPaiLeft > 0, "cannot kan when no piipai left"
    assert.isNotNull @pai
    pai = @pai = @pai.equivPai

    # build fuuro object
    if pai.isSuupai and pai.number == 5
      # include all akahai
      akahai = pai.akahai
      nAkahai = ..rulevar.dora.akahai[pai.S]
      ownPai = [akahai]*nAkahai ++ [pai]*(4 - nAkahai)
    else
      ownPai = [pai]*4
    @fuuro = {
      type: \ankan
      anchor: pai
      ownPai
      otherPai: null
      fromPlayer: null
      kakanPai: null
    }

    # master: try reveal doraHyouji
    if not ..isReplicate
      @newDoraHyouji ?= ..getNewDoraHyouji this

    if PH not instanceof PlayerHidden then return this
    assert.equal PH.countEquiv(pai), 4,
      "need 4 [#pai] in juntehai"
    if PP.riichi.accepted
      assert.isTrue @rulevar.riichi.ankan, "riichi ankan: not allowed by rule"
      # riichi ankan condition (simplified)
      #   basic: all tenpai decomps must have `pai` as koutsu
      #   okurikan: can only use tsumohai for ankan
      #
      # TODO: some impls have a more relaxed "basic" rule:
      #   tenpai/wait set must not change
      # "okurikan" rule above might still apply even with relaxed "basic"
      d = PH.tenpaiDecomp
      allKoutsu = d.decomps.every -> it.mentsu.some ->
        it.type == \koutsu and it.anchor == pai
      assert allKoutsu, "riichi ankan: hand decomposition must not change"
      if not @rulevar.riichi.okurikan
        assert.equal PH.tsumohai.equivPai, pai,
          "riichi ankan: okurikan not allowed by rule"

    return this

  apply: !-> with kyoku = @kyoku
    ..playerHidden[..currPlayer].removeEquivN pai, 4
    ..playerPublic[..currPlayer].fuuro.push @fuuro
    ..nKan++

    .._addDoraHyouji @newDoraHyouji

    ..rinshan = true
    ..currPai = @pai
    ..phase = \postAnkan
# }}}

Event.kakan = class Kakan # {{{
  # replicate-initiated
  # minimal:
  #   pai: Pai -- see `kakanPai` in fuuro/kakan
  # full:
  #   newDoraHyouji: ?[]Pai
  # private:
  #   fuuro

  (kyoku, {@pai}) -> with kyoku
    @type = \kakan
    @seq = ..seq
    if ..isReplicate
      assert.equal ..currPlayer, ..me,
        "cannot construct for others on replicate instance"
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \kakan
    assert.equal ..phase, \postTsumo
    PP = ..playerPublic[..currPlayer]
    PH = ..playerHidden[..currPlayer]

    assert.isNotNull @pai
    {equivPai} = pai = @pai

    assert ..nPiiPaiLeft > 0, "cannot kan when no piipai left"

    # find fuuro/minko object to be modified
    fuuro = PP.fuuro.find -> it.type == \minko and it.anchor == equivPai
    assert.isNotNull fuuro, "need existing minko of [#equivPai]"
    @fuuro = fuuro

    # master: try reveal doraHyouji
    if not ..isReplicate
      @newDoraHyouji ?= ..getNewDoraHyouji this

    if PH instanceof PlayerHidden
      assert.equal PH.count1(pai), 1, "need [#pai] in juntehai"

    return this

  apply: !-> with kyoku = @kyoku
    ..playerHidden[..currPlayer].removeEquivN @pai.equivPai, 1
    @fuuro
      ..type = \kakan
      ..kakanPai = @pai
    ..nKan++

    .._addDoraHyouji @newDoraHyouji

    ..rinshan = true
    ..currPai = @pai
    ..phase = \postKakan
# }}}

Event.tsumoAgari = class TsumoAgari # {{{
  # replicate-initiated:
  # minimal: null
  # full:
  #   juntehai: PlayerHidden::juntehai
  #   tsumohai: PlayerHidden::tsumohai
  # private:
  #   agari: Agari

  (kyoku) -> with kyoku
    @type = \tsumoAgari
    @seq = ..seq
    if ..isReplicate
      assert.equal ..currPlayer, ..me,
        "cannot construct for others on replicate instance"
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \tsumoAgari
    assert.equal ..phase, \postTsumo

    with ..playerHidden[..player]
      if .. instanceof PlayerHidden
        @{juntehai, tsumohai} = ..

    assert.isArray @juntehai
    assert (decompAgari Pai.binsFromArray @juntehai ++ @tsumohai .length > 0)

    @agari = .._agari this
    assert.isNotNull @agari

    return this

  apply: !-> with kyoku = @kyoku
    ..result
      ..type = \tsumoAgari
      for i til 4 => ..delta[i] += @agari.delta[i]
      ..takeKyoutaku ..player
      ..renchan = ..player == ..chancha
    .._end!
# }}}

Event.kyuushuukyuuhai = class Kyuushuukyuuhai # {{{
  # replicate-initiated
  # minimal: null
  # full:
  #   juntehai: PlayerHidden::juntehai
  #   tsumohai: PlayerHidden::tsumohai

  (kyoku) -> with kyoku
    @type = \kyuushuukyuuhai
    @seq = ..seq
    if ..isReplicate
      assert.equal ..currPlayer, ..me,
        "cannot construct for others on replicate instance"
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \kyuushuukyuuhai
    assert.equal ..phase, \postTsumo

    assert ..virgin
    with ..playerHidden[..currPlayer]
      if .. instanceof PlayerHidden
        @{juntehai, tsumohai} = ..
    assert.lengthOf @juntehai, 13
    assert.isNotNull @tsumohai

    nYaochuu =
      Pai.yaochuuFromBins Pai.binsFromArray @juntehai ++ @tsumohai
      .filter (>0) .length
    assert nYaochuu >= 9

    return this

  apply: !-> with kyoku = @kyoku
    ..result
      ..type = \ryoukyoku
      ..reason = \kyuushuukyuuhai
      ..renchan = true
    .._end!
# }}}

Event.declare = class Declare # {{{
  # SPECIAL: EVENT WRAPPER
  # minimal:
  #   what: chi/pon/daiminkan/ron
  #   args: (constructor args for constructing corresponding event)
  # partial:
  #   player: 0/1/2/3
  #   what
  # full:
  #   player
  #   what
  #   args

  (kyoku, {@what, @args}) -> with kyoku
    @type = \declare
    @seq = ..seq
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \declare
    assert @what in <[chi pon daiminkan ron]>#
    assert.isNull ..currDecl[@player], "you can only declare once"
    if @args?
      @player = @args.player
      new Event[@what](kyoku, @args) # validate only
    return this

  apply: !-> with kyoku = @kyoku
    ..currDecl.add @{what, player, args}
# }}}

Event.chi = class Chi # {{{
  # replicate-declared
  # minimal:
  #   player: 0/1/2/3 -- must be next player of `currPlayer`
  #   option 1:
  #     ownPai: [2]Pai -- should satisfy the following:
  #       both must exist in juntehai
  #       ownPai.0.equivNumber < ownPai.1.equivNumber
  #       `ownPai ++ kyoku.currPai` should form a shuntsu
  #   option 2:
  #     dir: Number
  #       < 0 : e.g. 34m chi 5m
  #       = 0 : e.g. 46m chi 5m
  #       > 0 : e.g. 67m chi 5m
  #     preferAkahai: Boolean
  #       suppose you have the choice of using akahai or normal 5:
  #         true : use akahai
  #         false: use normal 5
  # full:
  #   ownPai: [2]Pai
  # private:
  #   fuuro

  (kyoku, {@player, @ownPai, dir, preferAkahai = true}) -> with kyoku
    @type = \chi
    @seq = ..seq
    if ..isReplicate
      assert.equal @player, ..me,
        "cannot construct for others on replicate instance"
    if !@ownPai?
      # infer `ownPai` from `dir`, `preferAkahai`, and player's juntehai
      assert.isNumber dir
      assert.isBoolean preferAkahai
      with ..currPai # sutehai
        n = ..equivNumber # number
        P = Pai[..S] # suite
      # properties of ownPai:
      #
      switch
      | dir <  0 => assert n not in [1 2] ; op0 = P[n - 2] ; op1 = P[n - 1]
      | dir == 0 => assert n not in [1 9] ; op0 = P[n - 1] ; op1 = P[n + 1]
      | dir >  0 => assert n not in [8 9] ; op0 = P[n + 1] ; op1 = P[n + 2]
      @ownPai = [op0, op1]
      with ..playerHidden[@player]
        assert (..countEquiv op0 and ..countEquiv op1),
          "you must have [#{op0}#{op1}] in juntehai"
        # check whether we replace one of @ownPai with corresponding akahai
        if op0.number == 5 then i = 0 ; p5 = op0
        if op1.number == 5 then i = 1 ; p5 = op1
        if p5?
          p0 = p5.akahai
          p5n = ..count1 p5
          p0n = ..count1 p0
          # truth table: (has normal), (has akahai, prefer akahai) -> use akahai
          # |   | 00 | 01 | 11 | 10 |
          # | 0 | X  | X  | 1  | 1  |
          # | 1 | 0  | 0  | 1  | 0  |
          if p5n == 0 or (p0n > 0 and preferAkahai) then @ownPai[i] = p0
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \chi
    assert.equal @player, (..currPlayer + 1)%4, "can only chi from left/kamicha"
    assert.equal ..phase, \postDahai

    assert.lengthOf @ownPai, 2
    [a, b] = @ownPai
    c = ..currPai
    if a.N > b.N then [a, b] = @ownPai = [b, a]
    [p, q, r] = [a, b, c] .map (.equivPai) .sort Pai.compare
    assert (p.suite == q.suite == r.suite and p.succ == q and q.succ == r),
      "[#p#q#r] is not valid shuntsu"
      # NOTE: `equivPai` is shown (not original)

    # build fuuro object
    @fuuro = {
      type: \minjun
      anchor: p
      ownPai: @ownPai
      otherPai: c
      fromPlayer: ..currPlayer
      kakanPai: null
    }

    with ..playerHidden[@player] => if .. instanceof PlayerHidden
      assert (..count1 a and ..count1 b), "you must have [#a#b] in juntehai"

    return this

  apply: !-> with kyoku = @kyoku
    .._didNotHoujuu this
    ..playerHidden[@player].remove2 @ownPai.0, @ownPai.1
    ..playerPublic[@player]
      ..fuuro.push @fuuro
      ..menzen = false
    ..playerPublic[..currPlayer].lastSutehai.fuuroPlayer = @player

    ..currPlayer = @player
    ..phase = \postChiPon
# }}}

Event.pon = class Pon # {{{
  # replicate-declared
  # minimal:
  #   player: 0/1/2/3 -- must not be `currPlayer`
  #   option 1:
  #     ownPai: [2]Pai -- should satisfy the following:
  #       both must exist in juntehai
  #       `ownPai ++ kyoku.currPai` should form a koutsu (i.e. same `equivPai`)
  #   option 2:
  #     maxAkahai: Integer -- max number of akahai to use as ownPai
  # full:
  #   ownPai: [2]Pai
  # private:
  #   fuuro

  (kyoku, {@player, @ownPai, maxAkahai = 2}) -> with kyoku
    @type = \pon
    @seq = ..seq
    if ..isReplicate
      assert.equal @player, ..me,
        "cannot construct for others on replicate instance"
    if !@ownPai?
      # infer `ownPai` from `maxAkahai`
      assert.isNumber maxAkahai
      pai = ..currPai
      with ..playerHidden[@player]
        nAll = ..countEquiv pai
        assert nAll >= 2, "not enough [#pai] (you have #nAll, need 2)"
        if pai.number == 5
          akahai = Pai[pai.S][0]
          nAkahai = ..count1 akahai
          nAkahai <?= maxAkahai <? 2
        else
          nAkahai = 0
      @ownPai = switch nAkahai
      | 0 => [pai, pai]
      | 1 => [akahai, pai]
      | 2 => [akahai, akahai]
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \pon
    assert.notEqual @player, ..currPlayer
    assert.equal ..phase, \postDahai

    assert.lengthOf @ownPai, 2
    [a, b] = @ownPai
    c = ..currPai
    if a.N > b.N then [a, b] = @ownPai = [b, a]
    assert a.equivPai == b.equivPai == c.equivPai,
      "[#a#b#c] is not a valid koutsu"

    # build fuuro object
    @fuuro = {
      type: \minko
      anchor: c.equivPai
      ownPai: @ownPai
      otherPai: c
      fromPlayer: ..currPlayer
      kakanPai: null
    }

    with ..playerHidden[@player] => if .. instanceof PlayerHidden
      if a == b
        assert ..count1 a >= 2, "you must have [#a#b] in juntehai"
      else
        assert (..count1 a and ..count1 b), "you must have [#a#b] in juntehai"

    return this

  apply: Chi::apply # same object layout -- simply reuse
# }}}

Event.daiminkan = class Daiminkan # {{{
  # replicate-declared
  # minimal:
  #   player: 0/1/2/3 -- must not be `currPlayer`
  # full:
  #   newDoraHyouji: ?[]Pai
  # private:
  #   fuuro

  (kyoku, {@player}) -> with kyoku
    @type = \daiminkan
    @seq = ..seq
    if ..isReplicate
      assert.equal @player, ..me,
        "cannot construct for others on replicate instance"
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \daiminkan
    assert.notEqual @player, ..currPlayer
    assert.equal ..phase, \postDahai
    assert ..nPiiPaiLeft > 0, "cannot kan when no piipai left"
    pai = ..currPai

    # build fuuro object
    # list all 4 pai
    if pai.isSuupai and pai.number == 5
      # include all akahai
      akahai = pai.akahai
      nAkahai = ..rulevar.dora.akahai[pai.S]
      ownPai = [akahai]*nAkahai ++ [pai]*(4 - nAkahai)
    else
      ownPai = [pai]*4
    # exclude sutehai (not own)
    i = ownPai.indexOf pai
    ownPai.splice i, 1
    @fuuro = {
      type: \daiminkan
      pai, ownPai
      otherPai: ..currPai
      fromPlayer: ..currPlayer
      kakanPai: null
    }

    # master: try reveal doraHyouji
    if not ..isReplicate
      @newDoraHyouji ?= ..getNewDoraHyouji this

    with ..playerHidden[@player] => if .. instanceof PlayerHidden
      assert.equal ..countEquiv(..currPai), 3,
        "need 3 [#pai] in juntehai"

    return this

  apply: !-> with kyoku = @kyoku
    .._didNotHoujuu this
    ..playerHidden[@player].removeEquivN ..currPai.equivPai, 3
    ..playerPublic[@player]
      ..fuuro.push @fuuro
      ..menzen = false
    ..playerPublic[..currPlayer].lastSutehai.fuuroPlayer = @player
    ..nKan++

    .._addDoraHyouji @newDoraHyouji

    ..rinshan = true
    ..currPlayer = @player
    ..phase = \preTsumo # NOTE: no need to ask for ron
# }}}

Event.ron = class Ron # {{{
  # replicate-initiated
  # minimal:
  #   player: 0/1/2/3 -- must not be `currPlayer`
  #   isLast: ?Boolean -- added by master during resolve
  # full:
  #   juntehai: PlayerHidden::juntehai
  # private:
  #   houjuuPlayer: kyoku.currPlayer
  #   tenpaiDecomp: PlayerHidden::tenpaiDecomp
  #   agari: Agari

  (kyoku, {@player, @isLast = true}) -> with kyoku
    @type = \ron
    @seq = ..seq
    if ..isReplicate
      assert.equal @player, ..me,
        "cannot construct for others on replicate instance"
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \ron
    assert.notEqual @player, ..currPlayer
    assert ..phase in <[postDahai postAnkan postKakan]>#

    with ..playerHidden[@player]
      if .. instanceof PlayerHidden
        assert not ..furiten
        @{juntehai, tenpaiDecomp} = ..
    assert.isArray @juntehai
    @tenpaiDecomp ?= decompTenpai Pai.binsFromArray @juntehai
    assert ..isKeiten @tenpaiDecomp

    @agari = ..agari this
    assert.isNotNull @agari

    return this

  apply: !-> with kyoku = @kyoku
    ..result
      ..type = \ron
      for i til 4 => ..delta[i] += @agari.delta[i]
      ..takeKyoutaku @player
      ..renchan = ..renchan or @player == ..chancha
      ..[]agari.push @agari
    if @isLast then .._end!
# }}}

Event.nextTurn = class NextTurn # {{{
  # master-initiated
  # NOTE: no member

  (kyoku) -> with kyoku
    @type = \nextTurn
    @seq = ..seq
    assert not ..isReplicate
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \nextTurn
    assert ..phase in <[postDahai postAnkan postKakan]>#
    return this

  apply: !-> with kyoku = @kyoku
    .._didNotHoujuu this
    if ..phase == \postDahai
      ..currPlayer = (..currPlayer + 1)%4
    ..phase = \preTsumo
# }}}

Event.ryoukyoku = class Ryoukyoku # {{{
  # master-initiated
  # full:
  #   renchan: Boolean -> kyoku.result.renchan
  #   reason: String -> kyoku.result.reason
  #
  # NOTE: checks are all performed by master

  (kyoku, {@renchan, @reason}) -> with kyoku
    @type = \ryoukyoku
    @seq = ..seq
    assert not ..isReplicate
    @init kyoku

  init: (kyoku) -> with @kyoku = kyoku
    assert.equal @type, \ryoukyoku
    assert ..phase in <[postDahai postAnkan postKakan]>#
    return this

  apply: !-> with kyoku = @kyoku
    ..result{type, renchan, reason} = @
    .._end!
# }}}
