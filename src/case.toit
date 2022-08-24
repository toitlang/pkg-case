// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import bytes show Buffer

TO_UPPER_ ::= ToUpperConverter_
TO_LOWER_ ::= ToLowerConverter_
REG_EXP_CANONICALIZE_ ::= RegExpCanonicalizer_
REG_EXP_EQUIVALENCE_CLASSES_ ::= RegExpEquivalenceClasses_

// This is a case conversion library.  It is based on the idea of running a
// little program written in a bytecode.  The program makes calls to a user-
// supplied function, passing two integer Unicode codepoints as arguments.  The
// mapping (to upper case or to lower case) is defined by these code point
// pairs.

// While this is a very compact way to represent case mapping, it is not
// so convenient for actually converting strings to upper case or lower case.
// In order to do this we first observe that most texts are written in one
// language or very few languages.  Secondly, the characters used by a given
// language are grouped together in blocks, which always start on a codepoint
// that is divisible by 16.  See https://en.wikipedia.org/wiki/Unicode_block
// It follows that most texts access a limited number of blocks.

// We group the Unicode codepoint space into groups of 256, starting at a code
// point divisible by 256, which we call pages.  We use the bytecode programs
// to generate 256-entry sparse arrays on demand.  As an optimization, since
// each program generates mappings in strictly ascending order, we can stop
// running the program when the first codepoint appears that is above the page
// we are currently interested in.

// For to_upper_case and to_lower_case, the maps of the code point pages are simply
// lists of 256 strings, containing the 1-character string that is the mapping
// for the corresponding character (or rarely 2 or 3 characters).  Most Unicode
// characters do not have any case mapping (only about 1100 out of 29
// thousand), and we do not want to store lots of short strings for characters
// that are unchanged by case mapping, so a null represents "no change", and a
// null instead of an array provides a compact representation of a page where
// all characters map to themselves.

// For case canonicalization in JS-compatible regexps we only use the single-
// character upper case mappings.  In this case we use integer code points
// instead of strings in the page lists.  We also generate equivalence classes
// for use in regular expression []-style character classes.  These are in the
// form of small integer lists, where null represents the single entry
// equivalence class with just the original character in it.

PAGE_SHIFT_ ::= 8
PAGE_SIZE_  ::= 1 << PAGE_SHIFT_
PAGE_MASK_  ::= PAGE_SIZE_ - 1

to_some_case_ converter/CaseConverter src/string -> string:
  if src == "": return src

  b := Buffer
  index := 0
  substring_start := -1

  flush_substring := :
    if substring_start != -1:
      b.write src[substring_start..index]
      substring_start = -1

  src.do: | code |
    if code:
      dest / string? := converter.map code
      if dest == null:
        if substring_start == -1: substring_start = index
      else:
        //print "Gave $code ($(%c code)), got $dest ($dest))"
        flush_substring.call
        b.write dest
    index++
  if substring_start == 0: return src
  flush_substring.call
  return b.bytes.to_string

/**
Returns an upper-case version of the $source string.
If there are no lower-case characters in the source string,
  the source string is returned.
Understands Unicode, so it does correct case conversion for
  those alphabets that have a concept of upper and lower case.
Can convert one character to more than one character.  For example
  the german double s, "ß", is converted to "SS".
*/
to_upper source/string -> string:
  return to_some_case_ TO_UPPER_ source

/**
Returns a lower-case version of the $source string.
If there are no upper-case characters in the source string,
  the source string is returned.
Understands Unicode, so it does correct case conversion for
  those alphabets that have a concept of upper and lower case.
Can convert one character to more than one character.
*/
to_lower source/string -> string:
  return to_some_case_ TO_LOWER_ source

/**
Given a Unicode code point (numeric character), returns a
  list of other code points that are equivalent to it in a
  case-insensitive comparison.
Only returns single code points, not sequences.
Compatible with ECMAScript 5 regular expression concepts of
  case independence.
Returns null for code points that are only equivalent with
  themselves.
*/
reg_exp_equivalence_class rune/int -> List?/*<int>*/:
  return REG_EXP_EQUIVALENCE_CLASSES_.map rune

/**
Given a Unicode code point (numeric character), returns a
  canonical code point to which it is equivalent in a
  case-insensitive comparison.
Only handles single code points, not sequences, so for
  example the German double s, "ß", is not equivalent
  to the single "s" or the capital "S".
Compatible with ECMAScript 5 regular expression concepts of
  case independence.
*/
reg_exp_canonicalize rune/int -> int:
  answer := REG_EXP_CANONICALIZE_.map rune
  if answer == null: return rune  // Unchanged.
  return answer

abstract class CaseTable_:
  pages_ / Map/*<int, List>*/ := Map
  last_page_number_ / int := -1
  last_page_map_ / List? := null

  abstract add_page_ page/int -> List?

  map rune/int:
    page := rune >> PAGE_SHIFT_
    if page != last_page_number_:
      if not pages_.contains page: pages_[page] = add_page_ page
      last_page_number_ = page
      last_page_map_ = pages_[page]
    return last_page_map_ == null ? null : last_page_map_[rune & PAGE_MASK_]

abstract class CaseConverter extends CaseTable_:
  // f takes from/int to/int append/bool
  abstract run_ [f] -> none

  abstract add_entry page_list/List from/int to/int append/bool -> none

  add_page_ page/int -> List?:
    min := page << PAGE_SHIFT_
    max := min + PAGE_MASK_
    page_list / List? := null
    run_: | from to append |
      if from > max:
        continue.run_ false  // Stop now.
      else:
        if from >= min:
          if page_list == null: page_list = List PAGE_SIZE_
          add_entry page_list from to append
        continue.run_ true  // Continue.
    // May be null, meaning none of the characters on this page are mapped to
    // different characters.
    return page_list

abstract class StringCaseConverter extends CaseConverter:
  add_entry page_list/List from/int to/int append/bool -> none:
    to_string := string.from_rune to
    low_bits := from & PAGE_MASK_
    //print "In add_entry, $from-$to low_bits=$low_bits $page_list"
    //throw "foo"
    if append and page_list[low_bits] != null:
      // This is relatively rare, and the string never ends up larger than
      // 3 characters.
      page_list[low_bits] += to_string
    else:
      page_list[low_bits] = to_string

// Regular expression canonicalization uses the to-upper tables, but is specced
// to only use the single character mappings.  We use char codes, not short
// strings.
class RegExpCanonicalizer_ extends CaseConverter:
  add_entry page_list/List from/int to/int append/bool -> none:
    low_bits := from & PAGE_MASK_
    page_list[low_bits] = to

  run_ [f] -> none:
    interpreter := Interpreter TO_UPPER_PROGRAM_ true
    interpreter.interpret: | from to | f.call from to false  // Unused boolean argument.

// to_upper_case maps from char codes to short strings (1-3 characters).
class ToUpperConverter_ extends StringCaseConverter:
  run_ [f] -> none:
    overwrite_map := : | from to | f.call from to false
    append_map := : | from to | f.call from to true

    // Single character upper case mappings.
    (Interpreter TO_UPPER_PROGRAM_ true).interpret overwrite_map
    // First character of multi-character upper case mappings.
    (Interpreter S1_PROGRAM_ true).interpret overwrite_map
    // Second character of multi-character upper case mappings.
    (Interpreter S2_PROGRAM_ true).interpret append_map
    // Third character of multi-character upper case mappings.
    (Interpreter S3_PROGRAM_ true).interpret append_map

// to_lower_case maps from char codes to one-character strings.
class ToLowerConverter_ extends StringCaseConverter:
  run_ [f] -> none:
    (Interpreter TO_LOWER_PROGRAM_ false).interpret: | from to | f.call from to false

// The equivalence classes map from char codes to short lists of
// equivalent char codes.
class RegExpEquivalenceClasses_ extends CaseTable_:
  static LAST_ASCII_RUNE_ ::= 0x7f

  add_page_ page/int -> List?:
    min := page << PAGE_SHIFT_
    max := min + PAGE_MASK_
    // This will be the result from this method, a list of char codes for each
    // input char code, which the input char code is equivalent to.
    page_list / List := List PAGE_SIZE_

    // Temporary working map, that is discarded after this method returns.
    chars_that_map_to_each_canonical / Map/*<int, List<int>*/ := Map

    // For the first run of the case interpreter, this collects the upper case
    // characters that this block of characters map to.

    collect_canonicals := : | from to |
      if from > max:
        continue.collect_canonicals false  // Stop now.
      // Due to a strange rule in 21.2.2.8.2 step 3g we ignore mappings from
      // ASCII to non-ASCII.
      else:
        if from >= min and (to > LAST_ASCII_RUNE_ or from <= LAST_ASCII_RUNE_):
          if page_list == null: page_list = List PAGE_SIZE_
          page_list[from & PAGE_MASK_] = chars_that_map_to_each_canonical.get to --init=(: [])
        continue.collect_canonicals true  // Continue.

    // Get single character upper case mappings.
    (Interpreter TO_UPPER_PROGRAM_ true).interpret collect_canonicals

    if page_list == null: return null

    // For those characters that are not mentioned by the interpreter, this
    // means they map to themselves.  Add single-entry lists to the page to
    // reflect that.
    for code := min; code <= max; code++:
      if page_list[code & PAGE_MASK_] == null:
        list := chars_that_map_to_each_canonical.get code --init=(: [])
        page_list[code & PAGE_MASK_] = list
        list.add code
    chars_that_map_to_each_canonical.do --keys: | canonical |
      equivalence_class / List := chars_that_map_to_each_canonical[canonical]
      // If the canonical upper case character is not in the from-to range it
      // will not yet have been added to its own equivalence class.  Fix that.
      // It's OK to do "contains" on this list because they are never longer
      // than 4 elements.
      if not equivalence_class.contains canonical:
        equivalence_class.add canonical

    // For the second run of the case interpreter this collects all the
    // characters that map to one of the upper case forms we are interested in.
    collect_sets := : | from to |
      if (to > LAST_ASCII_RUNE_ or from <= LAST_ASCII_RUNE_) and
          (chars_that_map_to_each_canonical.contains to):
        chars_that_map_to_each_canonical[to].add from
      // Always continue, we have to run through all the to_upper_case byte codes.
      true

    (Interpreter TO_UPPER_PROGRAM_ true).interpret collect_sets

    at_least_one_mapping := false


    page_list.size.repeat:
      if page_list[it].size == 1:
        page_list[it] = null
      else:
        at_least_one_mapping = true

    if not at_least_one_mapping: return null

    return page_list

// These are bytecodes for the little interpreter below.  See the block
// of comments at the top of this file and above the interpreter for
// explanation.  Generated from the Unicode standard in 2014.  See
// tools/generate_case_tables.dart'
TO_UPPER_PROGRAM_ ::= #[
    0x01, 0xa1, 0x1a, 0x45, 0xba, 0x0e, 0xdc, 0x62, 0xaa, 0x16, 0x45, 0x4d,
    0x07, 0x45, 0x05, 0xf8, 0x6a, 0x18, 0x48, 0x01, 0xc9, 0x6a, 0x48, 0x48,
    0x50, 0x07, 0x48, 0x50, 0x16, 0x48, 0x50, 0x48, 0x48, 0x40, 0x01, 0xd3,
    0x62, 0x09, 0xc3, 0x72, 0x48, 0x50, 0x58, 0x58, 0x82, 0x50, 0x07, 0xf6,
    0x7a, 0x40, 0x08, 0xfd, 0x7a, 0x08, 0xe0, 0x72, 0x48, 0x48, 0x50, 0x50,
    0x82, 0x50, 0x58, 0x48, 0x50, 0x58, 0x48, 0x07, 0xf7, 0x6a, 0x84, 0x40,
    0x49, 0x40, 0x49, 0x40, 0x49, 0x07, 0x48, 0x40, 0x06, 0xce, 0x6a, 0x08,
    0x48, 0x50, 0x40, 0x49, 0x58, 0x13, 0x48, 0x58, 0x09, 0x48, 0x87, 0x50,
    0x02, 0x31, 0xfd, 0x63, 0x6b, 0x48, 0x83, 0x04, 0x48, 0x40, 0x02, 0x31,
    0xf1, 0x60, 0x60, 0x65, 0x05, 0xfc, 0x67, 0x6f, 0x65, 0x6b, 0x6f, 0x63,
    0x0a, 0x1e, 0xeb, 0x7a, 0x06, 0xd3, 0x62, 0x0a, 0x1e, 0xec, 0x6a, 0x06,
    0xd4, 0x6a, 0x0a, 0x1e, 0xcd, 0x62, 0x0a, 0x1e, 0xea, 0x6a, 0x06, 0xd8,
    0x61, 0x69, 0x02, 0x31, 0xe2, 0x62, 0x0a, 0x1e, 0xed, 0x72, 0x06, 0xdc,
    0x6a, 0x02, 0x31, 0xee, 0x62, 0x06, 0xdb, 0x74, 0x74, 0x85, 0x02, 0x31,
    0xe4, 0x72, 0x06, 0xe3, 0x75, 0x7d, 0x0a, 0x1e, 0xf1, 0x62, 0x06, 0xee,
    0x62, 0x09, 0xc4, 0x62, 0x06, 0xf0, 0x63, 0x63, 0x09, 0xc5, 0x62, 0x85,
    0x06, 0xf7, 0x62, 0x8a, 0x0a, 0x1e, 0xf4, 0x60, 0x60, 0x02, 0xa6, 0x0e,
    0xd9, 0x62, 0xab, 0x48, 0x58, 0x58, 0x0f, 0xfc, 0x03, 0x63, 0xae, 0x0e,
    0xc4, 0x64, 0x64, 0x63, 0x6b, 0x11, 0x45, 0x0e, 0xe3, 0x62, 0x09, 0x45,
    0x0e, 0xca, 0x64, 0x64, 0x6b, 0x65, 0x0e, 0xd8, 0x7a, 0x0e, 0xe6, 0x62,
    0x0e, 0xe0, 0x62, 0x4a, 0x0b, 0x48, 0x40, 0x0e, 0xda, 0x62, 0x47, 0x0f,
    0xf9, 0x62, 0x0d, 0xff, 0x6a, 0x0e, 0xd5, 0x72, 0x50, 0x50, 0xb2, 0x20,
    0x45, 0x0f, 0x47, 0x4f, 0x11, 0x48, 0x88, 0x1a, 0x48, 0x50, 0x06, 0x48,
    0x40, 0x13, 0xc0, 0x6a, 0x30, 0x48, 0xb0, 0x26, 0x46, 0x39, 0xb1, 0x06,
    0x42, 0x25, 0xbb, 0x0a, 0x1d, 0xfd, 0x7a, 0x02, 0x31, 0xe3, 0x7a, 0x02,
    0x80, 0x01, 0x0b, 0x48, 0x84, 0x01, 0x39, 0xe0, 0x6a, 0x84, 0x2f, 0x48,
    0x40, 0x01, 0x3c, 0xc7, 0x08, 0x63, 0x88, 0x01, 0x3c, 0xd7, 0x06, 0x63,
    0x8a, 0x01, 0x3c, 0xe7, 0x08, 0x63, 0x88, 0x01, 0x3c, 0xf7, 0x08, 0x63,
    0x88, 0x01, 0x3d, 0xc7, 0x06, 0x63, 0x8b, 0x01, 0x3d, 0xd7, 0x04, 0x6c,
    0x87, 0x01, 0x3d, 0xe7, 0x08, 0x63, 0x88, 0x01, 0x3e, 0xf9, 0x63, 0x63,
    0x01, 0x3f, 0xc7, 0x04, 0x63, 0x01, 0x3f, 0xd9, 0x63, 0x63, 0x01, 0x3f,
    0xf7, 0x63, 0x63, 0x01, 0x3f, 0xe9, 0x63, 0x63, 0x01, 0x3f, 0xf9, 0x63,
    0x73, 0x01, 0x3e, 0xc7, 0x08, 0x63, 0x88, 0x01, 0x3e, 0xd7, 0x08, 0x63,
    0x88, 0x01, 0x3e, 0xe7, 0x08, 0x63, 0x88, 0x01, 0x3e, 0xf7, 0x63, 0x6b,
    0x6d, 0x89, 0x0e, 0xd9, 0x6a, 0x83, 0x01, 0x3f, 0xcc, 0x6a, 0x8b, 0x01,
    0x3f, 0xd7, 0x63, 0x63, 0x8e, 0x01, 0x3f, 0xe7, 0x63, 0x7b, 0x7d, 0x8a,
    0x01, 0x3f, 0xfc, 0x7a, 0x05, 0x97, 0x02, 0x04, 0xf2, 0x7a, 0x9e, 0x10,
    0x43, 0x84, 0x40, 0x0d, 0x8b, 0x1a, 0x44, 0x1d, 0x86, 0x2e, 0x46, 0x56,
    0x58, 0x08, 0xf6, 0x66, 0x6e, 0x03, 0x48, 0x85, 0x50, 0x50, 0x88, 0x32,
    0x48, 0x87, 0x48, 0x48, 0x83, 0x48, 0x8b, 0x01, 0x02, 0xdf, 0x25, 0x63,
    0x6b, 0x6c, 0x84, 0x01, 0x03, 0xcd, 0x6a, 0x07, 0x24, 0x92, 0x17, 0x48,
    0x92, 0x0e, 0x48, 0x02, 0x86, 0x06, 0x48, 0x58, 0x1f, 0x48, 0x89, 0x48,
    0x50, 0x05, 0x48, 0x83, 0x48, 0x83, 0x48, 0x58, 0x0a, 0x48, 0x8a, 0x48,
    0x48, 0x0e, 0x9a, 0x0a, 0x1e, 0xf3, 0x6a, 0x9b, 0x01, 0x0e, 0xdf, 0x01,
    0x10, 0x63, 0x05, 0x0e, 0x81, 0x1a, 0x45, 0x13, 0x8d, 0x10, 0x0f, 0xff,
    0x28, 0x63, 0x21, 0xb0, 0x10, 0x31, 0xff, 0x33, 0x63, 0x2f, 0x8d, 0x20,
    0x45]

S1_PROGRAM_ ::= #[
    0x03, 0x9f, 0x01, 0xd3, 0x62, 0x01, 0x90, 0x04, 0xf0, 0x62, 0x98, 0x0a,
    0xfc, 0x62, 0x02, 0xa6, 0x01, 0xca, 0x62, 0x06, 0x9f, 0x0e, 0xd9, 0x62,
    0x9f, 0x0e, 0xe5, 0x62, 0x07, 0x96, 0x14, 0xf5, 0x62, 0x01, 0x24, 0x8e,
    0x01, 0xc8, 0x62, 0x01, 0xd1, 0x65, 0x65, 0x64, 0x01, 0xc1, 0x62, 0x02,
    0xb5, 0x0e, 0xe5, 0x04, 0x6a, 0xa8, 0x01, 0x3c, 0xc7, 0x08, 0x63, 0x01,
    0x3c, 0xc7, 0x08, 0x63, 0x01, 0x3c, 0xe7, 0x08, 0x63, 0x01, 0x3c, 0xe7,
    0x08, 0x63, 0x01, 0x3d, 0xe7, 0x08, 0x63, 0x01, 0x3d, 0xe7, 0x07, 0x63,
    0x73, 0x01, 0x3e, 0xfa, 0x62, 0x0e, 0xd1, 0x62, 0x0e, 0xc6, 0x6a, 0x0e,
    0xd1, 0x62, 0x62, 0x84, 0x62, 0x85, 0x01, 0x3f, 0xca, 0x62, 0x0e, 0xd7,
    0x62, 0x0e, 0xc9, 0x6a, 0x0e, 0xd7, 0x62, 0x62, 0x84, 0x62, 0x85, 0x64,
    0x72, 0x62, 0x62, 0x8a, 0x0e, 0xe5, 0x62, 0x62, 0x0e, 0xdd, 0x6e, 0x66,
    0x62, 0x8a, 0x01, 0x3f, 0xfa, 0x62, 0x0e, 0xe9, 0x62, 0x0e, 0xcf, 0x6a,
    0x0e, 0xe9, 0x62, 0x62, 0x84, 0x62, 0x0d, 0x2c, 0x83, 0x01, 0xc6, 0x05,
    0x62, 0x01, 0xd3, 0x62, 0x62, 0x8c, 0x15, 0xc4, 0x03, 0x62, 0x15, 0xce,
    0x62, 0x15, 0xc4, 0x62]

S2_PROGRAM_ ::= #[
    0x03, 0x9f, 0x01, 0xd3, 0x62, 0x01, 0xa9, 0x01, 0xce, 0x62, 0x02, 0xa6,
    0x0c, 0xcc, 0x62, 0x06, 0x9f, 0x0c, 0xc8, 0x62, 0x9f, 0x62, 0x07, 0x96,
    0x15, 0xd2, 0x62, 0x01, 0x24, 0x8e, 0x0c, 0xf1, 0x62, 0x0c, 0xc6, 0x64,
    0x64, 0x62, 0x0a, 0xfe, 0x62, 0x02, 0xb5, 0x0c, 0xd3, 0x04, 0x6a, 0xa8,
    0x0e, 0xd9, 0x2f, 0x62, 0x72, 0x62, 0x62, 0x6a, 0x0d, 0xc2, 0x62, 0x62,
    0x84, 0x0e, 0xd9, 0x62, 0x85, 0x62, 0x62, 0x6a, 0x0d, 0xc2, 0x62, 0x62,
    0x84, 0x0e, 0xd9, 0x62, 0x85, 0x0c, 0xc8, 0x62, 0x72, 0x0d, 0xc2, 0x62,
    0x0c, 0xc8, 0x62, 0x8a, 0x62, 0x62, 0x0c, 0xd3, 0x6a, 0x0d, 0xc2, 0x62,
    0x0c, 0xc8, 0x62, 0x8a, 0x0e, 0xd9, 0x62, 0x62, 0x6a, 0x0d, 0xc2, 0x62,
    0x62, 0x84, 0x0e, 0xd9, 0x62, 0x0d, 0x2c, 0x83, 0x01, 0xc3, 0x03, 0x65,
    0x01, 0xc6, 0x62, 0x62, 0x01, 0xd4, 0x62, 0x62, 0x8c, 0x15, 0xc6, 0x62,
    0x14, 0xf5, 0x62, 0x14, 0xfb, 0x62, 0x15, 0xc6, 0x62, 0x14, 0xfd, 0x62
    ]

S3_PROGRAM_ ::= #[
    0x0e, 0x90, 0x0c, 0xc1, 0x62, 0x9f, 0x62, 0x01, 0x2e, 0xa1, 0x69, 0x6b,
    0x0d, 0xc2, 0x6a, 0x01, 0x9f, 0x0e, 0xd9, 0x6a, 0x8e, 0x6a, 0x89, 0x0b,
    0xff, 0x63, 0x7b, 0x0d, 0xc2, 0x7a, 0x87, 0x0b, 0xff, 0x63, 0x7b, 0x0d,
    0xc2, 0x7a, 0x8c, 0x0e, 0xd9, 0x7a, 0x0d, 0x2c, 0x88, 0x01, 0xc6, 0x65,
    0x65]

TO_LOWER_PROGRAM_ ::= #[
    0x01, 0x81, 0x1a, 0x45, 0x01, 0xa5, 0x16, 0x45, 0x4d, 0x07, 0x45, 0xa1,
    0x18, 0x48, 0x01, 0xe9, 0x6a, 0x48, 0x48, 0x50, 0x07, 0x48, 0x50, 0x17,
    0x48, 0x03, 0xff, 0x62, 0x48, 0x48, 0x58, 0x09, 0xd3, 0x62, 0x48, 0x48,
    0x63, 0x48, 0x64, 0x63, 0x50, 0x07, 0xdd, 0x62, 0x09, 0xd7, 0x64, 0x64,
    0x48, 0x67, 0x6d, 0x09, 0xea, 0x61, 0x61, 0x58, 0x09, 0xec, 0x65, 0x6d,
    0x65, 0x03, 0x48, 0x0a, 0xc0, 0x62, 0x48, 0x75, 0x48, 0x67, 0x48, 0x64,
    0x63, 0x48, 0x48, 0x0a, 0xd2, 0x62, 0x58, 0x58, 0x84, 0x41, 0x48, 0x41,
    0x48, 0x41, 0x08, 0x48, 0x50, 0x08, 0x48, 0x50, 0x41, 0x48, 0x48, 0x06,
    0xd5, 0x62, 0x06, 0xff, 0x62, 0x14, 0x48, 0x06, 0xde, 0x6a, 0x09, 0x48,
    0x86, 0x02, 0x31, 0xe5, 0x62, 0x48, 0x06, 0xda, 0x62, 0x02, 0x31, 0xe6,
    0x72, 0x48, 0x06, 0xc0, 0x62, 0x0a, 0xc6, 0x65, 0x65, 0x05, 0x48, 0x04,
    0xa0, 0x48, 0x58, 0x58, 0x85, 0x0f, 0xf3, 0x7a, 0x83, 0x0e, 0xeb, 0x6b,
    0x63, 0x63, 0x6b, 0x0f, 0xcb, 0x6b, 0x63, 0x6b, 0x10, 0x45, 0x4d, 0x09,
    0x45, 0xa3, 0x42, 0x88, 0x0c, 0x48, 0x84, 0x0e, 0xf8, 0x72, 0x48, 0x0f,
    0xf2, 0x62, 0x50, 0x0d, 0xfa, 0x03, 0x63, 0x10, 0x47, 0x20, 0x45, 0xb0,
    0x11, 0x48, 0x88, 0x1b, 0x48, 0x13, 0xcf, 0x62, 0x06, 0x48, 0x50, 0x2f,
    0x48, 0x50, 0x26, 0x46, 0x2d, 0x89, 0x02, 0x33, 0xff, 0x25, 0x63, 0x6b,
    0x6c, 0x84, 0x02, 0x34, 0xed, 0x6a, 0x0b, 0x91, 0x0a, 0x2d, 0xef, 0x01,
    0x10, 0x63, 0x06, 0x42, 0x28, 0x8a, 0x01, 0x0b, 0x48, 0x88, 0x03, 0xdf,
    0x6a, 0x30, 0x48, 0x88, 0x01, 0x3b, 0xff, 0x08, 0x63, 0x88, 0x01, 0x3c,
    0xcf, 0x06, 0x63, 0x8a, 0x01, 0x3c, 0xdf, 0x08, 0x63, 0x88, 0x01, 0x3c,
    0xef, 0x08, 0x63, 0x88, 0x01, 0x3c, 0xff, 0x06, 0x63, 0x8b, 0x01, 0x3d,
    0xcf, 0x04, 0x6c, 0x87, 0x01, 0x3d, 0xdf, 0x08, 0x63, 0x98, 0x01, 0x3d,
    0xff, 0x08, 0x63, 0x88, 0x01, 0x3e, 0xcf, 0x08, 0x63, 0x88, 0x01, 0x3e,
    0xdf, 0x08, 0x63, 0x88, 0x01, 0x3e, 0xef, 0x63, 0x63, 0x01, 0x3d, 0xef,
    0x63, 0x63, 0x01, 0x3e, 0xf3, 0x62, 0x8b, 0x01, 0x3d, 0xf1, 0x04, 0x63,
    0x01, 0x3f, 0xc3, 0x62, 0x8b, 0x01, 0x3f, 0xcf, 0x63, 0x63, 0x01, 0x3d,
    0xf5, 0x63, 0x63, 0x8c, 0x01, 0x3f, 0xdf, 0x63, 0x63, 0x01, 0x3d, 0xf9,
    0x63, 0x63, 0x01, 0x3f, 0xe5, 0x62, 0x8b, 0x01, 0x3d, 0xf7, 0x63, 0x63,
    0x65, 0x63, 0x01, 0x3f, 0xf3, 0x62, 0x04, 0xa9, 0x0f, 0xc9, 0x7a, 0x01,
    0xeb, 0x62, 0x03, 0xe5, 0x62, 0x86, 0x02, 0x05, 0xce, 0x62, 0xad, 0x10,
    0x43, 0x93, 0x40, 0x0c, 0xb2, 0x1a, 0x44, 0x1c, 0xb0, 0x2f, 0x46, 0xb1,
    0x48, 0x09, 0xeb, 0x62, 0x01, 0x35, 0xfd, 0x62, 0x09, 0xfd, 0x72, 0x03,
    0x48, 0x09, 0xd1, 0x62, 0x09, 0xf1, 0x62, 0x09, 0xce, 0x64, 0x6c, 0x50,
    0x50, 0x86, 0x08, 0xfe, 0x63, 0x63, 0x32, 0x48, 0x87, 0x48, 0x48, 0x83,
    0x48, 0x07, 0x25, 0x8c, 0x17, 0x48, 0x92, 0x0e, 0x48, 0x02, 0x86, 0x06,
    0x48, 0x58, 0x1f, 0x48, 0x89, 0x48, 0x48, 0x01, 0x35, 0xf9, 0x62, 0x05,
    0x48, 0x83, 0x48, 0x09, 0xe5, 0x72, 0x48, 0x58, 0x0a, 0x48, 0x63, 0x09,
    0xd7, 0x67, 0x67, 0x09, 0xec, 0x72, 0x0a, 0xde, 0x62, 0x0a, 0xc7, 0x62,
    0x0a, 0xdd, 0x62, 0x0a, 0x2d, 0xd3, 0x62, 0x48, 0x48, 0x05, 0x1d, 0xa9,
    0x1a, 0x45, 0x13, 0x85, 0x10, 0x10, 0xe7, 0x28, 0x63, 0x21, 0x98, 0x10,
    0x32, 0xff, 0x33, 0x63, 0x2f, 0xad, 0x20, 0x45]

// When lower-casing characters we observe that the lower case version of a
// character is often a fixed distance from the upper case one.  The following
// array provides the distances that are common.  When upper-casing, the
// distances are negated.
COMMON_OFFSETS_ ::= #[1, 2, 8, 16, 26, 32, 48, 80]

// The bytecodes are designed to operate on a highly specialized three register
// machine.  The registers are X (e_xtend) L (Left) and R (Right).  There are no
// branches or loops, and L can only increase, never decrease.  Apart from
// instructions that manipulate the internal machine state, there are two
// instructions, EMIT_L_ and EMIT_R_, that declare a mapping from an original
// character to its mapped equivalent.
//
// The bytecodes are chosen from the observation that the mapping of a
// character is often close to the original character.  For this we use the
// EMIT_L_ instruction).  For the cases where the mapped character is a long or
// uncommon distance from the original character, we have a second register, R,
// which can indicate the mapped character.  For this we use the EMIT_R_
// instruction.
//
// Since bytecodes have limited space for constant operands, we provide the
// EXTEND_ instruction, which can provide high bits for later instructions.  It
// is also used to indicate repeat counts for EMITx instructions.
//
// Instructions/Bit pattern/Pseudocode
// EXTEND_:       00nnnnnn    X := (X << 6) + n
// EMIT_L_:       010nnmmm    Repeat (X == 0 ? 1 : X) times:
//                              Emit(L, L + COMMON_OFFSETS_[m])
//                              L += n+1
//                              X = 0
// EMIT_R_:       011nnmmm    Repeat (X == 0 ? 1 : X) times:
//                              R += m - bias
//                              Emit(L, R)
//                              L += n+1
//                              X = 0
// ADD_L_         10nnnnnn    L += (X << 6) + n
//                            X = 0
// LOAD_R_        11nnnnnn    R = (X << 6) + n
//                            X = 0

OP_CODE_MASK_ ::= 0xC0
EXTEND_ ::= 0x00
EMIT_ ::= 0x40
ADD_L_ ::= 0x80
LOAD_R_ ::= 0xC0

// Emit:
POST_INCREMENT_SHIFT_ ::= 3
POST_INCREMENT_MASK_ ::= 3

EMIT_L_ ::= 0x40
EMIT_R_ ::= 0x60
EMIT_MASK_ ::= 0xE0
EMIT_R_MASK_ ::= 0x07
EMIT_L_MASK_ ::= 0x07
EMIT_R_BIAS_ ::= 2

// Other instructions:
ARGUMENT_BITS_ ::= 6
ARGUMENT_MASK_ ::= 0x3f

class Interpreter:
  fixed_offsets_ / List
  byte_codes_ / ByteArray

  constructor .byte_codes_ to_upper/bool:
    sign := to_upper ? -1 : 1
    fixed_offsets_ = List COMMON_OFFSETS_.size:
      COMMON_OFFSETS_[it] * sign

  // Takes a block with arguments c/int mapped/int
  interpret [map] -> none:
    extend_reg := 0
    left_reg := 0
    right_reg := 0
    byte_codes_.size.repeat: 
      byte := byte_codes_[it]
      //print "byte code $(%02x byte)"
      op_code := byte & OP_CODE_MASK_
      argument := (byte & ARGUMENT_MASK_) + (extend_reg << ARGUMENT_BITS_)
      if op_code == EXTEND_:
        //print "EXTEND $argument"
        extend_reg = argument
      else:
        if op_code == EMIT_:
          if extend_reg == 0: extend_reg = 1
          increment := ((byte >> POST_INCREMENT_SHIFT_) & POST_INCREMENT_MASK_) + 1
          //print "EMIT$((byte & EMIT_MASK_) == EMIT_R_ ? "R" : "L") $increment ($extend_reg times)"
          extend_reg.repeat: | i |
            if (byte & EMIT_MASK_) == EMIT_R_:
              pre_increment := (byte & EMIT_R_MASK_) - EMIT_R_BIAS_
              right_reg += pre_increment
              if not map.call left_reg right_reg: return
            else:
              // EMIT_L_.
              offset := fixed_offsets_[byte & EMIT_L_MASK_]
              //print "offset from $(byte & EMIT_L_MASK_) = $offset"
              if not map.call left_reg left_reg + offset: return
            left_reg += increment
        else:
          if op_code == ADD_L_:
            //print "ADDL left_reg from $left_reg to $(left_reg + argument)"
            left_reg += argument
          else:
            // op_code == LOAD_R_.
            //print "LOAD_R $argument"
            right_reg = argument
        extend_reg = 0
