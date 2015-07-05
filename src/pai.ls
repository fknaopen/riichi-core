# Pai {tile}
# represents a tile with tenhou-compatible shorthand string
#
# e.g. Pai['7z']

SUUPAI = /([0-9])([mps])/
TSUUPAI = /([1-7])z/
TSUUPAI_ALT = /([ESWNBGRPFCZ])/
TSUUPAI_ALT_MAP =
  E: \1z, S: \2z, W: \3z, N: \4z # Fonpai {wind}
  B: \5z, G: \6z, R: \7z # Sangenpai {honor}
  P: \5z, F: \6z, C: \7z
  Z: \7z
SUITES = <[m p s z]>
SUITE_NUMBER = m: 0, p: 1, s: 2, z: 3

# template for extracting properties of a pai
# NOTE: this is NOT directly used -- use Pai[..] literals instead
class PaiClass
  (@paiStr) ->
    unless SUUPAI.test paiStr or
           TSUUPAI.test paiStr or
           TSUUPAI_ALT.test paiStr
      throw 0

  number: -> Number @paiStr[0]
  suite: -> @paiStr[1]
  suiteNumber: -> SUITE_NUMBER[@suite!]

  # shorthand for bin format (see below)
  S: -> @suiteNumber!
  N: -> @equivNumber! - 1

  # test if tile belongs to a category
  isSuupai: -> @suite! != 'z'
  isManzu: -> @suite! == 'm'
  isPinzu: -> @suite! == 'p'
  isSouzu: -> @suite! == 's'
  isAkahai: -> @isSuupai! && @number! == 0
  isRaotoupai: -> @isSuupai! && @number! in [1 9]
  isChunchanpai: -> @isSuupai! && @number! not in [1 9]
  isTsuupai: -> @suite! == 'z'
  isFonpai: -> @isTsuupai! && @number! in [1 2 3 4]
  isSangenpai: -> @isTsuupai! && @number! in [5 6 7]
  isYaochuupai: -> @isRaotoupai! || @isTsuupai!

  # handle akahai {red tile} (denoted `/0[mps]/` but acts as red `/5[mps]/`)
  equivNumber: ->
    n = @number!
    if @isAkahai! then 5 else n
  equivPai: ->
    new PaiClass(@equivNumber! + @suite!)

  # suupai successor (not wrapping)
  succ: ->
    n = @equivNumber!
    if @isTsuupai! or n == 9 then return null
    new PaiClass((n+1) + @suite!)

  # dora hyouji -> dora (wrapping)
  succDora: ->
    n = @equivNumber!
    if @isSuupai!
      if n == 9 then n = 1
      else ++n
    else
      if @isFonpai!
        if n == 4 then n = 1
        else ++n
      else
        if n == 7 then n = 5
        else ++n
    new PaiClass(n + @suite!)

# Build pai literals
module.exports = Pai = {}
f = -> @paiStr
proto = {toString: f, toJSON: f}
for m from 0 to 3
  for n from 0 to 9
    paiStr = n + SUITES[m]
    try new PaiClass paiStr catch e then continue
    Pai[paiStr] = ^^proto
for own paiStr, paiLit of Pai
  paiObj = new PaiClass paiStr
  for k, v of paiObj
    # convert predicate functions to values
    if v instanceof Function
      if v.length > 0 then continue
      v = paiObj[k]!
    # link pai literals
    if v instanceof PaiClass then v = Pai[v.paiStr]
    paiLit[k] = v

# link alternative shorthands
for alt, n of TSUUPAI_ALT_MAP
  Pai[alt] = Pai[n]
for n from 0 to 9
  a = Pai[n] = new Array 4
  for m from 0 to 3
    a[m] = Pai[n + SUITES[m]]

# export constants
Pai.SUITES = SUITES
Pai.SUITE_NUMBER = SUITE_NUMBER


# comparison function for sorting
#   m < p < s < z
#   m, p, s : 1 < 2 < 3 < 4 < 0 < 5 < 6 < 7 < 8 < 9
Pai.compare = (a, b) ->
  if d = a.suiteNumber - b.suiteNumber then return d
  if d = a.equivNumber - b.equivNumber then return d
  if d = a.number - b.number then return d
  return 0


# representations for a set of pai's:
#
# - contracted multi-pai string (tenhou-compatible)
#   e.g. 3347m40p11237s26z5m
#
# - sorted array of Pai literals
#
# - "bins" for simplified calculations
#   bins[0][i] => # of pai (i+1)-m  ;  0 <= i < 9
#   bins[1][i] => # of pai (i+1)-p  ;  0 <= i < 9
#   bins[2][i] => # of pai (i+1)-s  ;  0 <= i < 9
#   bins[3][i] => # of pai (i+1)-z  ;  0 <= i < 7
#
#   NOTE:
#   - bins format treats 0m/0p/0s as 5m/5p/5s
#   - for convenience, bins[3][7] = bins[3][8] = 0
#
# - bitmap, lsbit-first (for unique set of pai in single suite)
#   e.g. 0b000100100 => 36m/p/s/z

Pai.arrayFromString = (s) ->
  ret = []
  for run in s.match /\d*\D/g
    l = run.length
    if l <= 2
      # not contracted
      ret.push Pai[run]
    else
      # contracted
      suite = run[l-1]
      for i til l-1
        number = run[i]
        ret.push Pai[number + suite]
  ret.sort Pai.compare
  ret

Pai.stringFromArray = (paiArray) ->
  if !paiArray? then throw Error 'riichi-core: tehai: stringify: null input'
  l = paiArray.length
  if l == 0 then return ''

  # make a sorted copy
  paiArray = paiArray.slice!.sort Pai.compare
  ret = ''
  run = [paiArray[0].number]
  suite = paiArray[0].suite
  flush = -> ret += run.join('') + suite

  for i from 1 til l
    pai = paiArray[i]
    if pai.suite == suite
      run.push pai.number
    else
      flush!
      run = [pai.number]
      suite = pai.suite
  flush!
  return ret

Pai.binsFromString = (s) ->
  ret =
    [0 0 0 0 0 0 0 0 0]
    [0 0 0 0 0 0 0 0 0]
    [0 0 0 0 0 0 0 0 0]
    [0 0 0 0 0 0 0 0 0]
  for run in s.match /\d*\D/g
    l = run.length
    if l <= 2
      # not contracted
      pai = Pai[run]
      ret[pai.S][pai.N]++
    else
      # contracted
      suiteNumber = SUITE_NUMBER[run[l-1]]
      for i til (l-1)
        number = Number run[i]
        if number == 0 then number = 5
        ret[suiteNumber][number-1]++
  ret

Pai.binsFromArray = (paiArray) ->
  ret =
    [0 0 0 0 0 0 0 0 0]
    [0 0 0 0 0 0 0 0 0]
    [0 0 0 0 0 0 0 0 0]
    [0 0 0 0 0 0 0 0 0]
  for pai in paiArray
    ret[pai.S][pai.N]++
  ret

Pai.binFromBitmap = (bitmap) ->
  ret = [0 0 0 0 0 0 0 0 0]
  i = 0
  while bitmap
    ret[i++] = bitmap .&. 1
    bitmap .>>.= 1
  ret

Pai.arrayFromBitmapSuite = (bitmap, suite) ->
  # accept both 'm/p/s/z' and 0/1/2/3
  if suite.length then suite = SUITE_NUMBER[suite]
  n = 1
  ret = []
  while bitmap
    if bitmap .&. 1 then ret.push Pai[n][suite]
    n++
    bitmap .>>.= 1
  ret

# generate array of all 136 pai in uniform random order
# nAkahai: # of [0m, 0p, 0s] to replace corresponding [5m, 5p, 5s]
Pai.shuffleAll = (nAkahai = [1 1 1]) ->
  [m0, p0, s0] = nAkahai
  m5 = 4 - m0
  p5 = 4 - p0
  s5 = 4 - s0

  # meh.
  S = "1111222233334444#{'0'*m0}#{'5'*m5}6666777788889999m"+
      "1111222233334444#{'0'*p0}#{'5'*p5}6666777788889999p"+
      "1111222233334444#{'0'*s0}#{'5'*s5}6666777788889999s"+
      "1111222233334444555566667777z"
  a = Pai.arrayFromString S

  # shuffle
  for i from 136-1 til 0 by -1
    j = ~~(Math.random! * (i + 1))
    t = a[j] ; a[j] = a[i] ; a[i] = t
  a
