//! Tauri-style accelerators ("Alt+PrintScreen", "Ctrl+Shift+4") in RegisterHotKey terms:
//! a virtual-key code plus MOD_* flags.

pub const MOD_ALT: u32 = 0x1;
pub const MOD_CONTROL: u32 = 0x2;
pub const MOD_SHIFT: u32 = 0x4;
pub const MOD_WIN: u32 = 0x8;

pub const VK_SNAPSHOT: u32 = 0x2C;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hotkey {
    pub modifiers: u32,
    pub vk: u32,
}

fn modifier(token: &str) -> Option<u32> {
    Some(match token {
        "ctrl" | "control" | "cmdorctrl" | "cmdorcontrol" | "commandorctrl" | "commandorcontrol" => MOD_CONTROL,
        "alt" | "option" | "altgr" => MOD_ALT,
        "shift" => MOD_SHIFT,
        "super" | "win" | "windows" | "meta" | "cmd" | "command" => MOD_WIN,
        _ => return None,
    })
}

/// Virtual-key code for a key name, accepting Tauri names, `KeyboardEvent.code` names and plain characters.
fn key(token: &str) -> Option<u32> {
    let t = token.strip_prefix("key").filter(|r| r.len() == 1).unwrap_or(token);
    let t = t.strip_prefix("digit").filter(|r| r.len() == 1).unwrap_or(t);
    if t.len() == 1 {
        let c = t.as_bytes()[0];
        return match c {
            b'a'..=b'z' => Some(c.to_ascii_uppercase() as u32),
            b'0'..=b'9' => Some(c as u32),
            b'=' | b'+' => Some(0xBB),
            b'-' => Some(0xBD),
            b',' => Some(0xBC),
            b'.' => Some(0xBE),
            b'/' => Some(0xBF),
            b'`' => Some(0xC0),
            b'[' => Some(0xDB),
            b'\\' => Some(0xDC),
            b']' => Some(0xDD),
            b'\'' => Some(0xDE),
            b';' => Some(0xBA),
            _ => None,
        };
    }
    if let Some(n) = t.strip_prefix('f').and_then(|n| n.parse::<u32>().ok()) {
        return (1..=24).contains(&n).then_some(0x70 + n - 1);
    }
    if let Some(n) = t.strip_prefix("numpad").and_then(|n| n.parse::<u32>().ok()) {
        return (n <= 9).then_some(0x60 + n);
    }
    Some(match t {
        "printscreen" | "print" | "prtsc" | "prtscn" | "snapshot" => VK_SNAPSHOT,
        "space" => 0x20,
        "enter" | "return" | "numpadenter" => 0x0D,
        "tab" => 0x09,
        "escape" | "esc" => 0x1B,
        "backspace" => 0x08,
        "delete" | "del" => 0x2E,
        "insert" | "ins" => 0x2D,
        "home" => 0x24,
        "end" => 0x23,
        "pageup" => 0x21,
        "pagedown" => 0x22,
        "up" | "arrowup" => 0x26,
        "down" | "arrowdown" => 0x28,
        "left" | "arrowleft" => 0x25,
        "right" | "arrowright" => 0x27,
        "pause" => 0x13,
        "scrolllock" => 0x91,
        "numlock" => 0x90,
        "plus" | "equal" => 0xBB,
        "minus" => 0xBD,
        "comma" => 0xBC,
        "period" => 0xBE,
        "slash" => 0xBF,
        "backquote" => 0xC0,
        "bracketleft" => 0xDB,
        "backslash" => 0xDC,
        "bracketright" => 0xDD,
        "quote" => 0xDE,
        "semicolon" => 0xBA,
        "numpadadd" => 0x6B,
        "numpadsubtract" => 0x6D,
        "numpadmultiply" => 0x6A,
        "numpaddivide" => 0x6F,
        "numpaddecimal" => 0x6E,
        _ => return None,
    })
}

/// Splits on `+`, keeping a trailing `+` key ("Ctrl++").
fn tokens(acc: &str) -> Vec<String> {
    let acc = acc.trim();
    let (body, plus_key) = match acc.strip_suffix("++") {
        Some(rest) => (rest, true),
        None => (acc, false),
    };
    let mut out: Vec<String> = body.split('+').map(|t| t.trim().to_ascii_lowercase()).collect();
    if plus_key {
        out.push("+".into());
    }
    out
}

pub fn parse(acc: &str) -> Result<Hotkey, String> {
    let mut modifiers = 0;
    let mut vk = None;
    for token in tokens(acc) {
        if token.is_empty() {
            return Err(format!("\"{acc}\" is not a shortcut"));
        }
        if let Some(m) = modifier(&token) {
            modifiers |= m;
        } else if vk.is_some() {
            return Err(format!("\"{acc}\" has more than one key"));
        } else {
            vk = Some(key(&token).ok_or_else(|| format!("\"{token}\" is not a key Snipeshot knows"))?);
        }
    }
    let vk = vk.ok_or_else(|| format!("\"{acc}\" has no key"))?;
    Ok(Hotkey { modifiers, vk })
}

/// Human form for the tray menu: "Ctrl+Print Screen", "Ctrl+Shift+4".
pub fn display(acc: &str) -> String {
    let Ok(hk) = parse(acc) else { return acc.to_string() };
    let mut parts: Vec<String> = [(MOD_CONTROL, "Ctrl"), (MOD_ALT, "Alt"), (MOD_SHIFT, "Shift"), (MOD_WIN, "Win")]
        .iter()
        .filter(|(m, _)| hk.modifiers & m != 0)
        .map(|(_, name)| name.to_string())
        .collect();
    let key = tokens(acc).into_iter().rev().find(|t| modifier(t).is_none()).unwrap_or_default();
    parts.push(key_name(hk.vk, &key));
    parts.join("+")
}

fn key_name(vk: u32, token: &str) -> String {
    match vk {
        VK_SNAPSHOT => "Print Screen".into(),
        0x30..=0x39 | 0x41..=0x5A => char::from_u32(vk).map(String::from).unwrap_or_default(),
        0x70..=0x87 => format!("F{}", vk - 0x6F),
        _ => {
            let mut c = token.chars();
            c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_shortcuts_parse() {
        assert_eq!(parse("PrintScreen"), Ok(Hotkey { modifiers: 0, vk: VK_SNAPSHOT }));
        assert_eq!(parse("Alt+PrintScreen"), Ok(Hotkey { modifiers: MOD_ALT, vk: VK_SNAPSHOT }));
        assert_eq!(parse("Ctrl+PrintScreen"), Ok(Hotkey { modifiers: MOD_CONTROL, vk: VK_SNAPSHOT }));
    }

    #[test]
    fn letters_digits_and_function_keys() {
        assert_eq!(parse("Ctrl+Shift+4"), Ok(Hotkey { modifiers: MOD_CONTROL | MOD_SHIFT, vk: 0x34 }));
        assert_eq!(parse("Ctrl+Alt+S"), Ok(Hotkey { modifiers: MOD_CONTROL | MOD_ALT, vk: 0x53 }));
        assert_eq!(parse("F9"), Ok(Hotkey { modifiers: 0, vk: 0x78 }));
        assert_eq!(parse("F24").unwrap().vk, 0x87);
        assert_eq!(parse("super+KeyA"), Ok(Hotkey { modifiers: MOD_WIN, vk: 0x41 }));
        assert_eq!(parse("CmdOrCtrl+Digit5").unwrap(), Hotkey { modifiers: MOD_CONTROL, vk: 0x35 });
        assert_eq!(parse(" ctrl + shift + space ").unwrap(), Hotkey { modifiers: MOD_CONTROL | MOD_SHIFT, vk: 0x20 });
    }

    #[test]
    fn punctuation_and_named_keys() {
        assert_eq!(parse("Ctrl++").unwrap().vk, 0xBB);
        assert_eq!(parse("Ctrl+Plus").unwrap().vk, 0xBB);
        assert_eq!(parse("Alt+Minus").unwrap().vk, 0xBD);
        assert_eq!(parse("Shift+ArrowUp").unwrap().vk, 0x26);
        assert_eq!(parse("Numpad7").unwrap().vk, 0x67);
        assert_eq!(parse("Ctrl+BracketLeft").unwrap().vk, 0xDB);
    }

    #[test]
    fn rejects_nonsense() {
        assert!(parse("").is_err());
        assert!(parse("Ctrl+Shift").is_err());
        assert!(parse("Ctrl+A+B").is_err());
        assert!(parse("Ctrl+Hyper").is_err());
        assert!(parse("F25").is_err());
        assert!(parse("Ctrl++A").is_err());
    }

    #[test]
    fn display_names() {
        assert_eq!(display("PrintScreen"), "Print Screen");
        assert_eq!(display("Alt+PrintScreen"), "Alt+Print Screen");
        assert_eq!(display("shift+ctrl+4"), "Ctrl+Shift+4");
        assert_eq!(display("Ctrl+Alt+KeyS"), "Ctrl+Alt+S");
        assert_eq!(display("F9"), "F9");
        assert_eq!(display("Ctrl+Space"), "Ctrl+Space");
    }
}
