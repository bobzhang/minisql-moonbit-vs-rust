///|
/// Splits a script into statements on `;` outside quotes and comments.
/// Pieces holding only whitespace and comments are dropped.
pub fn split_statements(script : String) -> Array[String] {
  let out : Array[String] = []
  let n = script.length()
  let mut start = 0
  let mut i = 0
  let mut has_content = false
  while i < n {
    let c = script[i]
    if c == '\'' || c == '"' || c == '`' {
      has_content = true
      let mut j = i + 1
      while j < n {
        if script[j] == c {
          if j + 1 < n && script[j + 1] == c {
            j += 2
            continue
          }
          break
        }
        j += 1
      }
      i = j + 1
    } else if c == '[' {
      has_content = true
      let mut j = i + 1
      while j < n && script[j] != ']' {
        j += 1
      }
      i = j + 1
    } else if c == '-' && i + 1 < n && script[i + 1] == '-' {
      while i < n && script[i] != '\n' {
        i += 1
      }
    } else if c == '/' && i + 1 < n && script[i + 1] == '*' {
      let mut j = i + 2
      while j < n && !(script[j] == '*' && j + 1 < n && script[j + 1] == '/') {
        j += 1
      }
      i = if j < n { j + 2 } else { n }
    } else if c == ';' {
      if has_content {
        out.push(script[start:i].trim().to_owned())
      }
      has_content = false
      i += 1
      start = i
    } else {
      if !is_space_code(c) {
        has_content = true
      }
      i += 1
    }
  }
  if has_content && start < n {
    out.push(script[start:].trim().to_owned())
  }
  out
}

///|
/// Runs a whole script and returns the output text.
pub fn run_script(
  db : Database,
  script : String,
  emit : (String) -> Unit,
) -> Unit {
  for stmt in split_statements(script) {
    let res = db.execute(stmt) catch {
      SqlError(msg) => {
        emit(
          "Error: " +
          msg.replace_all(old="\n", new=" ").replace_all(old="\r", new=" ") +
          "\n",
        )
        continue
      }
    }
    if res.rows.length() > 0 {
      let sb = StringBuilder()
      for row in res.rows {
        for k, v in row {
          if k > 0 {
            sb.write_char('|')
          }
          sb.write_string(v.to_output())
        }
        sb.write_char('\n')
      }
      emit(sb.to_string())
    }
  }
}
