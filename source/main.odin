package odle

import "core:fmt"
import "core:os"
import "core:intrinsics"
import "core:math/rand"
import "core:math"
import "core:time"

import str "core:strings"
import sdl "vendor:sdl2"
import stb "vendor:stb/image"

WORD_LENGTH :: 5
NUM_GUESSES :: 6
WINDOW_WIDTH  :: 640
WINDOW_HEIGHT :: 480
ALLOW_ANY_GUESS :: false 
DRAW_STRING_SCALE :: 2

SHAKE_FREQUENCY :: 40
SHAKE_AMPLITUDE :: 5.0
SHAKE_DURATION :: 0.5

Font :: struct {
    texture: ^sdl.Texture,
    width, height: i32,
    glyphs_w, glyphs_h: i32,
}

Hint :: enum {
    Unknown,
    Incorrect,
    WrongPlace,
    Correct,
}

Guess :: struct {
    letter: [WORD_LENGTH]rune,
    hint: [WORD_LENGTH]Hint,
    len: i32,

    shake_start : f64,
    shake_amplitude : f64,
}

word_list : [dynamic]string
guesses : [NUM_GUESSES]Guess
num_guesses : i32
victory : bool
failure : bool
answer : string
dt : f64
frame_time : f64

fatal_error :: proc(message: string) {
    fmt.println("Fatal Error: ", message)
    os.exit(1)
}

make_rect :: proc(x, y, w, h : i32) -> ^sdl.Rect {
    result := new(sdl.Rect, context.temp_allocator)
    result^ = sdl.Rect{x, y, w, h}
    return result
}

expand :: proc(r: sdl.Rect, w, h: i32) -> ^sdl.Rect {
    result := new(sdl.Rect, context.temp_allocator)
    result^ = r
    result.x -= w / 2
    result.y -= h / 2
    result.w += w / 2
    result.h += h / 2
    return result
}

draw_string :: proc(renderer: ^sdl.Renderer, font: Font, x, y: i32, s: string) {

    source: sdl.Rect
    source.w = font.width / font.glyphs_w
    source.h = font.height / font.glyphs_h

    dest := source
    dest.w *= DRAW_STRING_SCALE
    dest.h *= DRAW_STRING_SCALE
    dest.x = x
    dest.y = y

    for c in s {
        index : i32 = cast(i32)c - cast(i32)' '
        row := index / font.glyphs_w
        col := index % font.glyphs_w
        source.x = col * source.w
        source.y = row * source.h
        sdl.RenderCopy(renderer, font.texture, &source, &dest)
        dest.x += dest.w
    }
}

draw_runes :: proc(renderer: ^sdl.Renderer, font: Font, x, y: i32, s: []rune) {

    source: sdl.Rect
    source.w = font.width / font.glyphs_w
    source.h = font.height / font.glyphs_h

    dest := source
    dest.w *= 3
    dest.h *= 3
    dest.x = x
    dest.y = y

    for c in s {
        index : i32 = cast(i32)c - cast(i32)' '
        row := index / font.glyphs_w
        col := index % font.glyphs_w
        source.x = col * source.w
        source.y = row * source.h
        sdl.RenderCopy(renderer, font.texture, &source, &dest)
        dest.x += dest.w
    }
}

set_fill_color :: proc(renderer: ^sdl.Renderer, hint: Hint) {
    switch (hint) {
    case .Unknown:    sdl.SetRenderDrawColor(renderer,  40,  40, 40, 255)
    case .Incorrect:  sdl.SetRenderDrawColor(renderer,  10,  10, 10, 255)
    case .WrongPlace: sdl.SetRenderDrawColor(renderer, 200, 200, 20, 255)
    case .Correct:    sdl.SetRenderDrawColor(renderer,  10, 200, 10, 255)
    }
}

set_border_color :: proc(renderer: ^sdl.Renderer, hint: Hint) {
    switch (hint) {
    case .Unknown:    sdl.SetRenderDrawColor(renderer,  60,  60, 60, 255)
    case .Incorrect:  sdl.SetRenderDrawColor(renderer,  30,  30, 30, 255)
    case .WrongPlace: sdl.SetRenderDrawColor(renderer, 210, 210, 30, 255)
    case .Correct:    sdl.SetRenderDrawColor(renderer,  20, 210, 20, 255)
    }
}

draw_guess :: proc(renderer: ^sdl.Renderer, font: Font, y: i32, s: Guess) {

    source: sdl.Rect
    source.w = font.width / font.glyphs_w
    source.h = font.height / font.glyphs_h

    dest := source
    dest.w *= 3
    dest.h *= 3

    SPACING :: 5
    jump := dest.w + SPACING
    total_width := WORD_LENGTH * dest.w + SPACING * (WORD_LENGTH - 1)

    dest.x = (WINDOW_WIDTH / 2) - (total_width / 2)
    if s.shake_amplitude > 0 {
        time_offset := frame_time - s.shake_start
        offset := math.sin(time_offset * SHAKE_FREQUENCY) * s.shake_amplitude
        dest.x += auto_cast offset
    }
    dest.y = y

    for c, i in s.letter {
        index : i32 = cast(i32)c - cast(i32)' '
        row := index / font.glyphs_w
        col := index % font.glyphs_w
        source.x = col * source.w
        source.y = row * source.h

        set_border_color(renderer, s.hint[i])
        sdl.RenderFillRect(renderer, expand(dest, 4, 4))
        set_fill_color(renderer, s.hint[i])
        sdl.RenderDrawRect(renderer, expand(dest, 4, 4))
        sdl.RenderCopy(renderer, font.texture, &source, &dest)
        dest.x += jump
    }
}


draw_keys :: proc(renderer: ^sdl.Renderer, font: Font, y: i32) {

    key_hints : [26]Hint

    for guess in guesses {
        for hint, i in guess.hint {
            if i >= cast(int)guess.len {
                break
            }
            key_index := i32(cast(i32)guess.letter[i] - cast(i32)sdl.Keycode.a)
            valid := key_index >= 0 && key_index < len(key_hints)
            assert(valid)
            if valid {
                if hint > key_hints[key_index] {
                    key_hints[key_index] = hint
                }
            }
        }
    }

    SPACING :: 5

    rows : []string = { "qwertyuiop", "asdfghjkl", "zxcvbnm" };

    draw_key_row :: proc(renderer: ^sdl.Renderer, font: Font, s: string, hints: []Hint, y: i32) {

        source: sdl.Rect
        source.w = font.width / font.glyphs_w
        source.h = font.height / font.glyphs_h

        dest := source
        dest.w *= 3
        dest.h *= 3

        total_width := cast(i32)len(s) * dest.w + SPACING * cast(i32)len(s) - 1
        dest.x = WINDOW_WIDTH / 2 - total_width / 2
        dest.y = y
        jump := dest.w + SPACING

        for c, i in s {
            hint_index := c - 'a'
            hint := hints[hint_index]

            dest_col : i32 = auto_cast i % cast(i32)len(s)
            dest.x = WINDOW_WIDTH / 2 - total_width / 2 + jump * dest_col

            index := c - ' '
            row := cast(i32)index / font.glyphs_w
            col := cast(i32)index % font.glyphs_w
            source.x = col * source.w
            source.y = row * source.h

            set_fill_color(renderer, hint)
            sdl.RenderFillRect(renderer, expand(dest, 4, 4))
            set_border_color(renderer, hint)
            sdl.RenderDrawRect(renderer, expand(dest, 4, 4))
            sdl.RenderCopy(renderer, font.texture, &source, &dest)
        }
    }

    for s, i in rows {
        draw_key_row(renderer, font, s, key_hints[:], y + i32(i) * (font.height / font.glyphs_h * 4))
    }
}

make_font :: proc(renderer: ^sdl.Renderer, filename: string) -> (Font, bool) {
    c : i32 = 4
    w, h: i32
    data := stb.load(str.clone_to_cstring(filename), &w, &h, &c, 4)
    defer stb.image_free(data)

    if data == nil {
        return Font{}, false
    }

    ByteColor :: struct {
        r, g, b, a: u8,
    }
    pixels : [^]ByteColor = cast(^ByteColor)data
    p := pixels[0:w*h]
    for pixel in &p {
        if pixel.r == 0 do pixel.a = 0
    }

    format : u32 = auto_cast sdl.PixelFormatEnum.RGBA32
    access := auto_cast sdl.TextureAccess.STREAMING

    font: Font
    font.texture = sdl.CreateTexture(renderer, format, access, w, h)
    font.width = w
    font.height = h
    font.glyphs_w = 18 // @hardcoded
    font.glyphs_h = 7

    success := sdl.UpdateTexture(font.texture, nil, data, w * 4) == 0
    sdl.SetTextureBlendMode(font.texture, sdl.BlendMode.BLEND)

    return font, success
}

valid_letter :: proc(key: sdl.Keycode) -> bool {
    return key >= sdl.Keycode.a && key <= sdl.Keycode.z
}

equals :: proc(str: string, runes: []rune) -> bool {
    match := true
    for c, i in str {
        if c != runes[i] {
            return false
        }
    }
    return true
}

is_in_word_list :: proc(word: []rune) -> bool {
    if len(word) != WORD_LENGTH {
        fmt.printf("\twrong len\n")
        return false
    }

    for s in word_list {
        if equals(s, word) {
            return true
        }
    }
    return false
}


evaluate :: proc(using guess: ^Guess) {
    used : [WORD_LENGTH]bool

    for c, i in answer {
        if letter[i] == c {
            hint[i] = .Correct
            used[i] = true
        }
    }

    for c, i in answer {
        if used[i] {
            continue
        }

        for g, gi in letter {
            if hint[gi] != .Unknown {
                continue
            }

            if c == g {
                hint[gi] = .WrongPlace
                used[i] = true
                break
            }
        }
    }

    for h in &hint {
        if h == .Unknown {
            h = .Incorrect
        }
    }
}

handle_key :: proc(key: sdl.Keycode) {

    if victory {
        return
    }
    
    if num_guesses >= NUM_GUESSES {
        return
    }

    using current_guess := &guesses[num_guesses]

    if key == sdl.Keycode.BACKSPACE {
        if len > 0 {
            len -= 1
            letter[len] = 0
            hint[len] = .Unknown
        }
        return
    }
    
    if current_guess.len < WORD_LENGTH  && valid_letter(key) {
        char := cast(rune)key
        letter[len] = char
        hint[len] = .Unknown
        len += 1
    }

    if (key == .RETURN || key == .KP_ENTER) && len == WORD_LENGTH {
        if equals(answer, letter[:]) {
            victory = true
        } else if is_in_word_list(letter[:]) /* || ALLOW_ANY_GUESS */ {
            evaluate(current_guess)

            num_guesses += 1
            if num_guesses >= NUM_GUESSES {
                num_guesses = NUM_GUESSES
                failure = true
            }
        } else {
            current_guess.shake_start = frame_time
            current_guess.shake_amplitude = SHAKE_AMPLITUDE
        }
    }
}


load_word_list :: proc() {
    data, success := os.read_entire_file_from_filename("word_list.txt")
    if !success {
        fatal_error("Could not read word_list.txt")
    }
    as_string := cast(string) data
    strings := str.split(as_string, "\n", context.temp_allocator)

    for s in strings {
        check := str.trim(s, " \r\n\t")
        if len(check) == WORD_LENGTH {
            append(&word_list, str.clone(check))
        } else {
            fmt.printf("Invalid word in list: {}\n", check)
        }
    }

    if len(word_list) == 0 {
        fatal_error("Empty word list!")
    }
}

main :: proc() {

    load_word_list()

    window_flags : sdl.WindowFlags = { .INPUT_FOCUS, .ALLOW_HIGHDPI }
    window := sdl.CreateWindow("Odle - The Odin Wordle!", sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED, WINDOW_WIDTH, WINDOW_HEIGHT, window_flags)
    if window == nil {
        fatal_error("Unable to open window")
    }
    render_flags : sdl.RendererFlags = { .PRESENTVSYNC }
    renderer := sdl.CreateRenderer(window, -1, render_flags)
    if renderer == nil {
        fatal_error("Unable to create renderer")
    }

    defer sdl.DestroyWindow(window)
    defer sdl.DestroyRenderer(renderer)

    font, font_created := make_font(renderer, "font.png")
    if !font_created {
        fatal_error("Unable to load font file")
    }
    defer sdl.DestroyTexture(font.texture)
    rng := rand.create(u64(time.now()._nsec))
    answer = word_list[rand.uint32(&rng) % cast(u32)len(word_list)]

    if false {
        answer = "baabd"
        exists := false
        for s in word_list {
            if answer == s {
                exists = true
                break
            }
        }
        if !exists {
            append(&word_list, answer)
        }
    }

    running := true
    start_time := time.now()
    last_time := start_time
    for running {
        free_all(context.temp_allocator)
        now := time.now()
        frame_time = time.duration_seconds(time.diff(start_time, now))
        dt = time.duration_seconds(time.diff(last_time, now))
        last_time = now

        event: sdl.Event
        for sdl.PollEvent(&event) != 0 {

            #partial switch(event.type) {
                case .QUIT: {
                    running = false
                    break
                }

                case .KEYDOWN: {
                    key := event.key.keysym.sym
                    handle_key(key)
                }
            }
        }

        sdl.SetRenderDrawColor(renderer, 10, 10, 10, 255)
        if victory {
            sdl.SetRenderDrawColor(renderer, 10, 200, 10, 255)
        }
        sdl.RenderClear(renderer)

        glyph_width := font.width / font.glyphs_w
        title := "ODLE"
        draw_string(renderer, font, (WINDOW_WIDTH / 2.0) - (glyph_width * (cast(i32)len(title) / 2) * DRAW_STRING_SCALE), 30, title)
        for i in 0..<NUM_GUESSES {
            draw_guess(renderer, font, 60 + cast(i32)i * 30, guesses[i])
            if guesses[i].shake_amplitude > 0 {
                guesses[i].shake_amplitude -= max((SHAKE_AMPLITUDE * dt) / SHAKE_DURATION, 0)
            }
        }
        draw_keys(renderer, font, 70 + (NUM_GUESSES + 1) * 30)

        if failure {
            draw_string(renderer, font, 20, 50, "Oh no!")
            draw_string(renderer, font, 20, 70, fmt.tprintf("It was {}", answer))
        }

        sdl.RenderPresent(renderer)
    }
}
