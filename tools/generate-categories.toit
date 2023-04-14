import bytes show Buffer
import host.file
import reader show BufferedReader

import ..src.case

// Unicode character categories.
// The special category Al means "alternating case, upper case first.
CATEGORIES := [
    "Cc", "Cf", "Co", "Cs", "Ll", "Lu",
    "Lo", "Lt", "Lm", "Mc", "Me", "Mn",
    "Nd", "Nl", "No", "Pc", "Pd", "Pe",
    "Pf", "Pi", "Po", "Ps", "Sc", "Sk",
    "Sm", "So", "Zl", "Zp", "Zs", "Al",
]

CATEGORY_ALTERNATING ::= CATEGORIES.index_of "Al"
CATEGORY_CONTROL     ::= CATEGORIES.index_of "Cc"
CATEGORY_LOWER       ::= CATEGORIES.index_of "Ll"
CATEGORY_UPPER       ::= CATEGORIES.index_of "Lu"

PRINT_DEBUG ::= false

set_x commands/Buffer value -> none:
  writing := false
  if PRINT_DEBUG: print "X $value"
  for i := 30; i >= 0; i -= 6:
    if writing or value >> i > 0:
      byte := (value >> i) & 0x3f
      if PRINT_DEBUG: print "  EXTEND 0x$(%02x byte)"
      commands.write_byte byte
      writing = true
      value &= ~(0x3f << i)

// Generate a program that emits the categories in the UnicodeData.txt file.
// See the bytecodes in case.toit.
main:
  commands := Buffer
  fd := file.Stream.for_read "unicode/UnicodeData.txt"
  reader := BufferedReader fd
  current_category := 0
  // Categories are indices into the CATEGORIES array.
  current_range_start := 0
  r := 0  // The value of the R register.

  // Any characters that are skipped are assumed to be lower case.
  // This lets us handle areas with alternating case efficiently.

  // Named block.
  emit := : | end/int |
    if end != current_range_start:

      str := ""
      if current_category != CATEGORY_CONTROL:
        limit := min (current_range_start + 100) end
        for i := current_range_start; i < limit; i++:
          if not 0xd800 <= i <= 0xdfff: str += "$(%c i)"
      if PRINT_DEBUG: print "$(%04x current_range_start)..$(%04x end - 1) $CATEGORIES[current_category] $str"

      emit_category := current_category == CATEGORY_ALTERNATING ? CATEGORY_UPPER : current_category
      emit_repeats := end - current_range_start
      trailing_emit_rs := 0
      step := 1
      if current_category == CATEGORY_ALTERNATING:
        step = 2
        if emit_repeats % 2 != 0:
          // Odd number of characters in an alternating range, so we must emit
          // the trailing capital letter. R will already set up from the
          // alternating range, and EMIT_R_ defaults to one repeat, so it's just
          // one byte we will need to emit.
          trailing_emit_rs++
        emit_repeats /= 2
      pre_increment := 0
      if r != emit_category:
        assert: emit_category <= 0x3f
        // The m field in the EMIT_R_ bytecode is a pre-increment value for R.
        // It is biased by EMIT_R_BIAS_, so it can range from
        // -EMIT_R_BIAS_ to EMIT_R_MASK_ - EMIT_R_BIAS_.
        if PRINT_DEBUG: print "R $emit_category"
        if -EMIT_R_BIAS_ <= emit_category - r <= EMIT_R_MASK_ - EMIT_R_BIAS_ and emit_repeats < 3:
          pre_increment = emit_category - r
          if emit_repeats == 2:
            trailing_emit_rs++
            emit_repeats = 1
          if PRINT_DEBUG: print "  (Handle with a pre-increment of $pre_increment)"
        else:
          byte := LOAD_R_ + emit_category
          if PRINT_DEBUG: print "  LOAD_R $(emit_category & 0x3f) 0x$(%02x byte)"
          commands.write_byte byte
        r = emit_category
      assert: emit_repeats != 0
      if emit_repeats != 1:
        set_x commands emit_repeats
      m := pre_increment + EMIT_R_BIAS_
      if PRINT_DEBUG: print "Write $(%04x current_range_start)..$(%04x end - 1) $(CATEGORIES[current_category])"
      byte := EMIT_R_ + ((step - 1) << POST_INCREMENT_SHIFT_) + m
      if PRINT_DEBUG: print "  EMIT_R 0x$(%02x byte)"
      commands.write_byte byte
      trailing_emit_rs.repeat:
        byte = EMIT_R_ + EMIT_R_BIAS_
        if PRINT_DEBUG: print "  EMIT_R 0x$(%02x byte)"
        commands.write_byte byte
      current_range_start = end

  while line := reader.read_line:
    parts := line.split ";"
    code := int.parse --radix=16 parts[0]
    category_string := parts[2]
    category := CATEGORIES.index_of category_string
    if category == -1:
      throw category_string
    if category != current_category:
      if current_category == CATEGORY_UPPER and
          category == CATEGORY_LOWER and
          code == current_range_start + 1:
        current_category = CATEGORY_ALTERNATING
      else if current_category == CATEGORY_ALTERNATING and
          category == CATEGORY_LOWER and
          (code - current_range_start) % 2 == 1:
        null // Do nothing, we're still alternating.
      else if current_category == CATEGORY_ALTERNATING and
          category == CATEGORY_UPPER and
          (code - current_range_start) % 2 == 0:
        null // Do nothing, we're still alternating.
      else:
        emit.call code
        current_category = category
  emit.call 0x110000

  result := commands.bytes
  if PRINT_DEBUG: print "Size $result.size"
  print "/// Generated by tools/generate-categories.toit from UnicodeData.txt."
  print "/// A $(result.size)-byte program that emits the Unicode character categories."
  print "UNICODE_CATEGORY_TABLE ::= #["
  List.chunk_up 0 result.size 12: | f t l |
    part := result[f..t]
    list := List l: "0x$(%02x part[it])"
    line := "    $(list.join ", "),"
    print line
  print "]"
