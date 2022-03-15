package odle

import "core:fmt"
import "core:os"
import "core:intrinsics"
import "core:math/rand"
import "core:math"
import "core:time"
import "core:mem"

import str "core:strings"
import sdl "vendor:sdl2"
import stb "vendor:stb/image"

WORD_LENGTH :: 5
NUM_GUESSES :: 6
WINDOW_WIDTH  :: 1000
WINDOW_HEIGHT :: 800
ALLOW_ANY_GUESS :: false
DRAW_STRING_SCALE :: 3
DRAW_GUESS_SCALE  :: 6
DRAW_KEYS_SCALE  :: 5

SHAKE_FREQUENCY :: 40
SHAKE_AMPLITUDE :: 5.0
SHAKE_DURATION :: 0.5

Mode :: enum {
    MENU,
    GAME,
}

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

font: Font
renderer: ^sdl.Renderer
word_list : [dynamic]string

guesses : [NUM_GUESSES]Guess
num_guesses : i32
victory : bool
failure : bool
answer : string

mode : Mode = .MENU
dt : f64
frame_time : f64

active_button: string
next_active_button: string


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

get_glyph :: proc(c: rune) -> ^sdl.Rect {
    source := new(sdl.Rect, context.temp_allocator)
    source.w = font.width / font.glyphs_w
    source.h = font.height / font.glyphs_h

    index : i32 = cast(i32)c - cast(i32)' '
    row := index / font.glyphs_w
    col := index % font.glyphs_w
    source.x = col * source.w
    source.y = row * source.h

    return source
}

draw_string :: proc(x, y: i32, s: string) {

    dest: sdl.Rect
    dest.w = (font.width / font.glyphs_w)  * DRAW_STRING_SCALE
    dest.h = (font.height / font.glyphs_h) * DRAW_STRING_SCALE
    dest.x = x
    dest.y = y

    for c in s {
        sdl.RenderCopy(renderer, font.texture, get_glyph(c), &dest)
        dest.x += dest.w
    }
}

draw_string_centered :: proc(x, y: i32, s: string) {
    glyph_width := font.width / font.glyphs_w
    glyph_height := font.height / font.glyphs_h
    draw_string(x - (glyph_width * cast(i32)len(s) * DRAW_STRING_SCALE) / 2, y - (glyph_height / 2) * DRAW_STRING_SCALE, s)
}

draw_runes :: proc(x, y: i32, s: []rune) {

    dest: sdl.Rect = ---
    dest.w = (font.width / font.glyphs_w)  * 3
    dest.h = (font.height / font.glyphs_h) * 3
    dest.x = x
    dest.y = y

    for c in s {
        sdl.RenderCopy(renderer, font.texture, get_glyph(c), &dest)
        dest.x += dest.w
    }
}

set_fill_color :: proc(hint: Hint, b: u8 = 0) {
    switch (hint) {
    case .Unknown:    sdl.SetRenderDrawColor(renderer,  40 + b,  40 + b, 40 + b, 255)
    case .Incorrect:  sdl.SetRenderDrawColor(renderer,  10 + b,  10 + b, 10 + b, 255)
    case .WrongPlace: sdl.SetRenderDrawColor(renderer, 200 + b, 200 + b, 20 + b, 255)
    case .Correct:    sdl.SetRenderDrawColor(renderer,  10 + b, 200 + b, 10 + b, 255)
    }
}

set_border_color :: proc(hint: Hint, b: u8 = 0) {
    switch (hint) {
    case .Unknown:    sdl.SetRenderDrawColor(renderer,  60 + b,  60 + b, 60 + b, 255)
    case .Incorrect:  sdl.SetRenderDrawColor(renderer,  30 + b,  30 + b, 30 + b, 255)
    case .WrongPlace: sdl.SetRenderDrawColor(renderer, 210 + b, 210 + b, 30 + b, 255)
    case .Correct:    sdl.SetRenderDrawColor(renderer,  20 + b, 210 + b, 20 + b, 255)
    }
}

draw_guess :: proc(y: i32, s: Guess) {
    dest: sdl.Rect
    dest.w = font.width / font.glyphs_w * DRAW_GUESS_SCALE
    dest.h = font.height / font.glyphs_h * DRAW_GUESS_SCALE

    SPACING :: 1 * DRAW_GUESS_SCALE
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
        set_fill_color(s.hint[i])
        sdl.RenderFillRect(renderer, expand(dest, 4, 4))
        set_border_color(s.hint[i])
        sdl.RenderDrawRect(renderer, expand(dest, 4, 4))
        sdl.RenderCopy(renderer, font.texture, get_glyph(c), &dest)
        dest.x += jump
    }
}

draw_keys :: proc(y: i32) {

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

    SPACING :: 3 * DRAW_KEYS_SCALE
    rows : []string = { "qwertyuiop", "asdfghjkl", "zxcvbnm" };

    draw_key_row :: proc(renderer: ^sdl.Renderer, font: Font, s: string, hints: []Hint, y: i32) {
        dest: sdl.Rect
        dest.w = font.width / font.glyphs_w * DRAW_KEYS_SCALE
        dest.h = font.height / font.glyphs_h * DRAW_KEYS_SCALE

        total_width := cast(i32)len(s) * dest.w + SPACING * cast(i32)len(s) - 1
        dest.x = WINDOW_WIDTH / 2 - total_width / 2
        dest.y = y
        jump := dest.w + SPACING

        for c, i in s {
            hint_index := c - 'a'
            hint := hints[hint_index]

            dest_col : i32 = auto_cast i % cast(i32)len(s)
            dest.x = WINDOW_WIDTH / 2 - total_width / 2 + jump * dest_col

            button_string := s[i:i+1]
            brightness : u8 = 0
            _, mx, my := mouse_state()
            is_hovered := contains(dest, mx, my)
            if active_button == button_string {
                brightness = 20
            } else if is_hovered {
                brightness = 10
            }

            set_fill_color(hint, brightness)
            sdl.RenderFillRect(renderer, expand(dest, 4, 4))
            set_border_color(hint, brightness)
            sdl.RenderDrawRect(renderer, expand(dest, 4, 4))
            sdl.RenderCopy(renderer, font.texture, get_glyph(c), &dest)

            if button_behavior(button_string, dest) {
                handle_key(cast(sdl.Keycode)c, false)
            }
        }
    }

    y_offset :: proc(row: i32) -> i32 {
        return (row + 5) * (((font.height / font.glyphs_h) + 3) * DRAW_KEYS_SCALE)
    }

    for s, i in rows {
        draw_key_row(renderer, font, s, key_hints[:], y + y_offset(cast(i32)i))
    }

    br: sdl.Rect
    br.x = WINDOW_WIDTH / 2 - 225
    br.y = y + y_offset(auto_cast len(rows) + 0)
    br.w = 200
    br.h = 50

    if button("Backspace", br) {
        handle_key(sdl.Keycode.BACKSPACE, false)
    }
    br.x = WINDOW_WIDTH / 2 + 25
    if button("Enter", br) {
        handle_key(sdl.Keycode.RETURN, false)
    }
}

load_font :: proc() {
    c : i32 = 4
    w, h: i32
    raw_data := #load("../font.png")
    data := stb.load_from_memory(&raw_data[0], i32(len(raw_data)), &w, &h, &c, 4)
    defer stb.image_free(data)

    if data == nil {
        fatal_error("Could not initialize the font")
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

    font.texture = sdl.CreateTexture(renderer, format, access, w, h)
    font.width = w
    font.height = h
    font.glyphs_w = 18 // @hardcoded
    font.glyphs_h = 7

    success := sdl.UpdateTexture(font.texture, nil, data, w * 4) == 0
    if !success {
        fatal_error("Unable to update font texture")
    }
    sdl.SetTextureBlendMode(font.texture, sdl.BlendMode.BLEND)
}

valid_letter :: proc(key: sdl.Keycode) -> bool {
    return key >= sdl.Keycode.a && key <= sdl.Keycode.z
}

equals :: proc(str: string, runes: []rune) -> bool {
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

handle_key :: proc(key: sdl.Keycode, repeat: bool) {

    if mode == .MENU {
        if (key == .RETURN || key == .KP_ENTER) {
            start_game()
        }
        return
    }

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
            if !repeat {
                shake_start = frame_time
                shake_amplitude = SHAKE_AMPLITUDE
            }
        }
    }
}


load_word_list :: proc() {
    data := #load("../word_list.txt")
    as_string := cast(string) data
    strings := str.split(as_string, "\n", context.temp_allocator)

    for s in strings {
        check := str.trim(s, " \r\n\t")
        if len(check) == WORD_LENGTH {
            append(&word_list, str.clone(check))
        } else if len(check) > 0 {
            fmt.printf("Invalid word in list: {}\n", check)
        }
    }

    if len(word_list) == 0 {
        fatal_error("Empty word list!")
    }
}

rect_center :: proc(r: sdl.Rect) -> (i32, i32) {
    x := r.x + r.w / 2
    y := r.y + r.h / 2
    return x, y
}

mouse_state :: proc() -> (pressed: bool, x, y: i32) {
    mx, my: i32
    button_state := sdl.GetMouseState(&mx, &my)
    return (button_state & 1 != 0), mx, my
}

contains :: proc(r: sdl.Rect, x, y: i32) -> bool {
    return x > r.x && x < r.x + r.w && y > r.y && y < r.y + r.h
}

button_behavior :: proc(text: string, r: sdl.Rect) -> bool {
    pressed, mx, my := mouse_state()
    is_hovered := contains(r, mx, my)
    result := false
    if active_button == text {
        if pressed {
            next_active_button = text
        }
        result = is_hovered && pressed == false
    }

    if is_hovered && pressed && len(active_button) == 0 {
        next_active_button = text
    }

    return result
}

button :: proc(text: string, r: sdl.Rect) -> bool {
    result := button_behavior(text, r)
    _, mx, my := mouse_state()
    is_hovered := contains(r, mx, my)
    rect := r
    if active_button == text {
        sdl.SetRenderDrawColor(renderer,  80,  80, 80, 255)
        sdl.RenderFillRect(renderer, &rect)
        sdl.SetRenderDrawColor(renderer,  99,  99, 99, 255)
        sdl.RenderDrawRect(renderer, &rect)
    } else if is_hovered {
        sdl.SetRenderDrawColor(renderer,  50,  50, 50, 255)
        sdl.RenderFillRect(renderer, &rect)
        sdl.SetRenderDrawColor(renderer,  70,  70, 70, 255)
        sdl.RenderDrawRect(renderer, &rect)
    } else {
        sdl.SetRenderDrawColor(renderer,  30,  30, 30, 255)
        sdl.RenderFillRect(renderer, &rect)
        sdl.SetRenderDrawColor(renderer,  50,  50, 50, 255)
        sdl.RenderDrawRect(renderer, &rect)
    }

    tx, ty := rect_center(r)
    draw_string_centered(tx, ty, text)
    return result
}

start_game :: proc() {
    mem.zero_item(&guesses)
    num_guesses = 0
    victory = false
    failure = false

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
    } else {
        rng := rand.create(u64(time.now()._nsec))
        answer = word_list[rand.uint32(&rng) % cast(u32)len(word_list)]
    }


    mode = .GAME
}

main :: proc() {
    window_flags : sdl.WindowFlags = { .INPUT_FOCUS, .ALLOW_HIGHDPI }
    window := sdl.CreateWindow("Odle - The Odin Wordle!", sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED, WINDOW_WIDTH, WINDOW_HEIGHT, window_flags)
    if window == nil {
        fatal_error("Unable to open window")
    }
    render_flags : sdl.RendererFlags = { .PRESENTVSYNC }
    renderer = sdl.CreateRenderer(window, -1, render_flags)
    if renderer == nil {
        fatal_error("Unable to create renderer")
    }

    load_word_list()
    load_font()

    defer sdl.DestroyWindow(window)
    defer sdl.DestroyRenderer(renderer)
    defer sdl.DestroyTexture(font.texture)

    mode = .MENU
    running := true
    start_time := time.now()
    last_time := start_time
    for running {
        free_all(context.temp_allocator)
        now := time.now()
        frame_time = time.duration_seconds(time.diff(start_time, now))
        dt = time.duration_seconds(time.diff(last_time, now))
        last_time = now

        active_button = next_active_button
        next_active_button = ""

        event: sdl.Event
        for sdl.PollEvent(&event) != 0 {

            #partial switch(event.type) {
                case .QUIT: {
                    running = false
                    break
                }

                case .KEYDOWN: {
                    key := event.key.keysym.sym
                    handle_key(key, cast(bool)event.key.repeat)
                }
            }
        }

        if mode == .MENU {
            sdl.SetRenderDrawColor(renderer, 10, 10, 10, 255)
            if victory {
                sdl.SetRenderDrawColor(renderer, 10, 200, 10, 255)
            }
            sdl.RenderClear(renderer)

            draw_string_centered(WINDOW_WIDTH / 2, 100, "ODLE")
            if button("Play", sdl.Rect{WINDOW_WIDTH / 2 - 50, 400, 120, 50}) {
                start_game()
            }
            if button("Quit", sdl.Rect{WINDOW_WIDTH / 2 - 50, 480, 120, 50}) {
                running = false
            }

        } else {
            sdl.SetRenderDrawColor(renderer, 10, 10, 10, 255)
            if victory {
                sdl.SetRenderDrawColor(renderer, 10, 200, 10, 255)
            }
            sdl.RenderClear(renderer)

            draw_string_centered((WINDOW_WIDTH / 2.0), 30, "ODLE")
            for i in 0..<NUM_GUESSES {
                draw_guess(60 + cast(i32)i * 10 * DRAW_GUESS_SCALE, guesses[i])
                if guesses[i].shake_amplitude > 0 {
                    guesses[i].shake_amplitude -= max((SHAKE_AMPLITUDE * dt) / SHAKE_DURATION, 0)
                }
            }
            draw_keys((NUM_GUESSES + 1) * 30)

            if failure {
                draw_string(20, 300, "Oh no!")
                draw_string(20, 350, fmt.tprintf("It was {}", answer))
            }

            if failure || victory {
                if button("Menu", sdl.Rect{10, 10, 200, 50}) {
                    victory = false
                    failure = false
                    mode = .MENU
                }
                if button("Restart", sdl.Rect{10, 80, 200, 50}) {
                    start_game()
                }
                if button("Quit", sdl.Rect{10, 150, 200, 50}) {
                    running = false
                }
            }
        }

        sdl.RenderPresent(renderer)
    }
}
