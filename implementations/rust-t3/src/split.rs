// Splits a script into statements on ';' outside quotes and comments.

pub fn split(input: &str) -> Vec<String> {
    let b = input.as_bytes();
    let n = b.len();
    let mut out = Vec::new();
    let mut start = 0;
    let mut has_content = false;
    let mut i = 0;
    while i < n {
        let c = b[i];
        match c {
            b'\'' | b'"' | b'`' => {
                has_content = true;
                i += 1;
                while i < n {
                    if b[i] == c {
                        if i + 1 < n && b[i + 1] == c {
                            i += 2;
                            continue;
                        }
                        break;
                    }
                    i += 1;
                }
                i += 1;
            }
            b'[' => {
                has_content = true;
                while i < n && b[i] != b']' {
                    i += 1;
                }
                i += 1;
            }
            b'-' if i + 1 < n && b[i + 1] == b'-' => {
                while i < n && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if i + 1 < n && b[i + 1] == b'*' => {
                i += 2;
                while i < n && !(b[i] == b'*' && i + 1 < n && b[i + 1] == b'/') {
                    i += 1;
                }
                i += 2;
            }
            b';' => {
                if has_content {
                    out.push(input[start..i].to_string());
                }
                has_content = false;
                i += 1;
                start = i;
            }
            _ => {
                if !c.is_ascii_whitespace() {
                    has_content = true;
                }
                i += 1;
            }
        }
    }
    if has_content && start < n {
        out.push(input[start..].to_string());
    }
    out
}
