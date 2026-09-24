use std::{collections::BTreeMap, fmt, ops::Range};

const MAX_DEPTH: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Key {
    Integer(i64),
    String(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Nil,
    Boolean(bool),
    Integer(i64),
    Float(f64),
    String(Vec<u8>),
    Table(Table),
}

pub type Table = BTreeMap<Key, Value>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Statement {
    pub name: Range<usize>,
    pub value: Range<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Unexpected {
        offset: usize,
        expected: &'static str,
    },
    UnterminatedString(usize),
    UnterminatedComment(usize),
    InvalidNumber(usize),
    InvalidEscape(usize),
    DuplicateKey(usize),
    TooDeep(usize),
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unexpected { offset, expected } => {
                write!(formatter, "expected {expected} at byte {offset}")
            }
            Self::UnterminatedString(offset) => {
                write!(formatter, "unterminated string at byte {offset}")
            }
            Self::UnterminatedComment(offset) => {
                write!(formatter, "unterminated comment at byte {offset}")
            }
            Self::InvalidNumber(offset) => write!(formatter, "invalid number at byte {offset}"),
            Self::InvalidEscape(offset) => write!(formatter, "invalid escape at byte {offset}"),
            Self::DuplicateKey(offset) => write!(formatter, "duplicate key at byte {offset}"),
            Self::TooDeep(offset) => write!(formatter, "table nested too deeply at byte {offset}"),
        }
    }
}

/// Lexes every top-level `name = value` assignment and reports their byte ranges.
///
/// No value is built, so statements the companion does not own stay opaque bytes.
pub fn scan_statements(source: &[u8]) -> Result<Vec<Statement>, Error> {
    let mut lexer = Lexer::new(source);
    let mut statements = Vec::new();

    loop {
        let start = lexer.next_token()?;
        match start.token {
            Token::End => return Ok(statements),
            Token::Semicolon => continue,
            Token::Name(_) => {}
            _ => {
                return Err(Error::Unexpected {
                    offset: start.span.start,
                    expected: "a top-level name",
                });
            }
        }

        lexer.expect(&Token::Equals, "=")?;
        let value = lexer.skip_value()?;
        statements.push(Statement {
            name: start.span,
            value,
        });
    }
}

pub fn parse_value(source: &[u8]) -> Result<Value, Error> {
    let mut lexer = Lexer::new(source);
    let first = lexer.next_token()?;
    let value = parse_from(&mut lexer, first, 0)?;

    let trailing = lexer.next_token()?;
    if trailing.token == Token::End {
        Ok(value)
    } else {
        Err(Error::Unexpected {
            offset: trailing.span.start,
            expected: "the end of the value",
        })
    }
}

fn parse_from(lexer: &mut Lexer<'_>, token: Spanned, depth: usize) -> Result<Value, Error> {
    let Spanned { token, span } = token;
    match token {
        Token::Nil => Ok(Value::Nil),
        Token::True => Ok(Value::Boolean(true)),
        Token::False => Ok(Value::Boolean(false)),
        Token::Integer(value) => Ok(Value::Integer(value)),
        Token::Float(value) => Ok(Value::Float(value)),
        Token::String(text) => Ok(Value::String(text)),
        Token::LeftBrace => parse_table(lexer, span.start, depth + 1).map(Value::Table),
        _ => Err(Error::Unexpected {
            offset: span.start,
            expected: "a value",
        }),
    }
}

fn parse_table(lexer: &mut Lexer<'_>, start: usize, depth: usize) -> Result<Table, Error> {
    if depth > MAX_DEPTH {
        return Err(Error::TooDeep(start));
    }

    let mut entries = BTreeMap::new();
    let mut next_index: i64 = 1;

    loop {
        let Spanned { token, span } = lexer.next_token()?;
        let offset = span.start;
        let (key, value) = match token {
            Token::RightBrace => return Ok(entries),
            Token::End => {
                return Err(Error::Unexpected {
                    offset,
                    expected: "}",
                });
            }
            Token::LeftBracket => {
                let key = lexer.next_token()?;
                let key = match key.token {
                    Token::Integer(value) => Key::Integer(value),
                    Token::String(text) => Key::String(text),
                    _ => {
                        return Err(Error::Unexpected {
                            offset: key.span.start,
                            expected: "a string or integer key",
                        });
                    }
                };
                lexer.expect(&Token::RightBracket, "]")?;
                lexer.expect(&Token::Equals, "=")?;
                let next = lexer.next_token()?;
                (key, parse_from(lexer, next, depth)?)
            }
            Token::Name(name) => {
                lexer.expect(&Token::Equals, "=")?;
                let next = lexer.next_token()?;
                (Key::String(name), parse_from(lexer, next, depth)?)
            }
            token => {
                let index = next_index;
                next_index += 1;
                (
                    Key::Integer(index),
                    parse_from(lexer, Spanned { token, span }, depth)?,
                )
            }
        };

        if entries.insert(key, value).is_some() {
            return Err(Error::DuplicateKey(offset));
        }

        let separator = lexer.next_token()?;
        match separator.token {
            Token::Comma | Token::Semicolon => {}
            Token::RightBrace => return Ok(entries),
            _ => {
                return Err(Error::Unexpected {
                    offset: separator.span.start,
                    expected: ", or }",
                });
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Token {
    LeftBrace,
    RightBrace,
    LeftBracket,
    RightBracket,
    Comma,
    Semicolon,
    Equals,
    Name(Vec<u8>),
    String(Vec<u8>),
    Integer(i64),
    Float(f64),
    True,
    False,
    Nil,
    End,
}

struct Spanned {
    token: Token,
    span: Range<usize>,
}

struct Lexer<'a> {
    source: &'a [u8],
    offset: usize,
}

impl<'a> Lexer<'a> {
    const fn new(source: &'a [u8]) -> Self {
        Self { source, offset: 0 }
    }

    fn expect(&mut self, token: &Token, expected: &'static str) -> Result<(), Error> {
        let found = self.next_token()?;
        if found.token == *token {
            Ok(())
        } else {
            Err(Error::Unexpected {
                offset: found.span.start,
                expected,
            })
        }
    }

    fn skip_value(&mut self) -> Result<Range<usize>, Error> {
        let first = self.next_token()?;
        let start = first.span.start;

        match first.token {
            Token::LeftBrace => {
                let mut depth = 1_usize;
                loop {
                    let next = self.next_token()?;
                    match next.token {
                        Token::LeftBrace => depth += 1,
                        Token::RightBrace => {
                            depth -= 1;
                            if depth == 0 {
                                return Ok(start..next.span.end);
                            }
                        }
                        Token::End => {
                            return Err(Error::Unexpected {
                                offset: next.span.start,
                                expected: "}",
                            });
                        }
                        _ => {}
                    }
                }
            }
            Token::String(_)
            | Token::Integer(_)
            | Token::Float(_)
            | Token::True
            | Token::False
            | Token::Nil => Ok(first.span),
            _ => Err(Error::Unexpected {
                offset: start,
                expected: "a value",
            }),
        }
    }

    fn next_token(&mut self) -> Result<Spanned, Error> {
        self.skip_trivia()?;

        let start = self.offset;
        let Some(byte) = self.peek() else {
            return Ok(Spanned {
                token: Token::End,
                span: start..start,
            });
        };

        let token = match byte {
            b'{' => self.single(Token::LeftBrace),
            b'}' => self.single(Token::RightBrace),
            b'[' => self.single(Token::LeftBracket),
            b']' => self.single(Token::RightBracket),
            b',' => self.single(Token::Comma),
            b';' => self.single(Token::Semicolon),
            b'=' => self.single(Token::Equals),
            b'"' | b'\'' => Token::String(self.read_string(byte)?),
            b'-' | b'0'..=b'9' => self.read_number(start)?,
            b'_' | b'a'..=b'z' | b'A'..=b'Z' => self.read_name(),
            _ => {
                return Err(Error::Unexpected {
                    offset: start,
                    expected: "a value",
                });
            }
        };

        Ok(Spanned {
            token,
            span: start..self.offset,
        })
    }

    const fn single(&mut self, token: Token) -> Token {
        self.offset += 1;
        token
    }

    fn peek(&self) -> Option<u8> {
        self.source.get(self.offset).copied()
    }

    fn skip_trivia(&mut self) -> Result<(), Error> {
        loop {
            match self.peek() {
                Some(byte) if byte.is_ascii_whitespace() => self.offset += 1,
                Some(b'-') if self.source.get(self.offset + 1) == Some(&b'-') => {
                    let start = self.offset;
                    self.offset += 2;
                    if let Some(level) = self.open_long_bracket() {
                        self.skip_long_comment(start, level)?;
                    } else {
                        while !matches!(self.peek(), None | Some(b'\n')) {
                            self.offset += 1;
                        }
                    }
                }
                _ => return Ok(()),
            }
        }
    }

    fn open_long_bracket(&mut self) -> Option<usize> {
        if self.peek() != Some(b'[') {
            return None;
        }

        let mut cursor = self.offset + 1;
        let mut level = 0;
        while self.source.get(cursor) == Some(&b'=') {
            level += 1;
            cursor += 1;
        }

        if self.source.get(cursor) == Some(&b'[') {
            self.offset = cursor + 1;
            Some(level)
        } else {
            None
        }
    }

    fn skip_long_comment(&mut self, start: usize, level: usize) -> Result<(), Error> {
        while let Some(byte) = self.peek() {
            if byte == b']' {
                let mut cursor = self.offset + 1;
                let mut found = 0;
                while self.source.get(cursor) == Some(&b'=') {
                    found += 1;
                    cursor += 1;
                }
                if found == level && self.source.get(cursor) == Some(&b']') {
                    self.offset = cursor + 1;
                    return Ok(());
                }
            }
            self.offset += 1;
        }

        Err(Error::UnterminatedComment(start))
    }

    fn read_name(&mut self) -> Token {
        let start = self.offset;
        while matches!(
            self.peek(),
            Some(b'_' | b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9')
        ) {
            self.offset += 1;
        }

        match &self.source[start..self.offset] {
            b"true" => Token::True,
            b"false" => Token::False,
            b"nil" => Token::Nil,
            name => Token::Name(name.to_vec()),
        }
    }

    fn read_number(&mut self, start: usize) -> Result<Token, Error> {
        if self.peek() == Some(b'-') {
            self.offset += 1;
        }

        let digits = self.offset;
        self.skip_digits();
        let mut is_float = false;

        if self.peek() == Some(b'.') {
            is_float = true;
            self.offset += 1;
            self.skip_digits();
        }

        if matches!(self.peek(), Some(b'e' | b'E')) {
            is_float = true;
            self.offset += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.offset += 1;
            }
            let exponent = self.offset;
            self.skip_digits();
            if self.offset == exponent {
                return Err(Error::InvalidNumber(start));
            }
        }

        if self.offset == digits {
            return Err(Error::InvalidNumber(start));
        }

        let text = str::from_utf8(&self.source[start..self.offset])
            .map_err(|_| Error::InvalidNumber(start))?;
        if !is_float && let Ok(value) = text.parse::<i64>() {
            return Ok(Token::Integer(value));
        }

        text.parse::<f64>()
            .map(Token::Float)
            .map_err(|_| Error::InvalidNumber(start))
    }

    fn skip_digits(&mut self) {
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.offset += 1;
        }
    }

    fn read_string(&mut self, quote: u8) -> Result<Vec<u8>, Error> {
        let start = self.offset;
        self.offset += 1;
        let mut text = Vec::new();

        loop {
            let Some(byte) = self.peek() else {
                return Err(Error::UnterminatedString(start));
            };
            self.offset += 1;

            match byte {
                b'\n' => return Err(Error::UnterminatedString(start)),
                b'\\' => self.read_escape(&mut text)?,
                byte if byte == quote => return Ok(text),
                byte => text.push(byte),
            }
        }
    }

    fn read_escape(&mut self, text: &mut Vec<u8>) -> Result<(), Error> {
        let start = self.offset - 1;
        let Some(byte) = self.peek() else {
            return Err(Error::InvalidEscape(start));
        };
        self.offset += 1;

        let decoded = match byte {
            b'a' => 0x07,
            b'b' => 0x08,
            b'f' => 0x0c,
            b'n' => b'\n',
            b'r' => b'\r',
            b't' => b'\t',
            b'v' => 0x0b,
            b'\\' | b'"' | b'\'' => byte,
            b'\n' | b'\r' => {
                // A backslash before a line break escapes the break itself, and CRLF is one break.
                if matches!(self.peek(), Some(b'\n' | b'\r')) && self.peek() != Some(byte) {
                    self.offset += 1;
                }
                text.push(b'\n');
                return Ok(());
            }
            b'0'..=b'9' => {
                let mut value = u32::from(byte - b'0');
                for _ in 0..2 {
                    let Some(digit @ b'0'..=b'9') = self.peek() else {
                        break;
                    };
                    value = value * 10 + u32::from(digit - b'0');
                    self.offset += 1;
                }
                u8::try_from(value).map_err(|_| Error::InvalidEscape(start))?
            }
            _ => return Err(Error::InvalidEscape(start)),
        };

        text.push(decoded);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Error, Key, Value, parse_value, scan_statements};

    fn text(value: &str) -> Value {
        Value::String(value.as_bytes().to_vec())
    }

    #[test]
    fn skips_a_string_that_looks_like_the_next_assignment() {
        let source = b"CONFIG = {\n\t[\"note\"] = \"} ARBITRAGE_DATABASE = {\",\n}\nARBITRAGE_DATABASE = {\n}\n";
        let statements = scan_statements(source).unwrap();

        assert_eq!(statements.len(), 2);
        assert_eq!(&source[statements[1].name.clone()], b"ARBITRAGE_DATABASE");
        assert_eq!(&source[statements[1].value.clone()], b"{\n}");
    }

    #[test]
    fn keeps_integer_and_string_keys_apart() {
        let value = parse_value(b"{\n[1] = 10,\n[\"1\"] = 20,\n}").unwrap();
        let Value::Table(table) = value else {
            panic!("expected a table");
        };
        let entries: Vec<_> = table.iter().collect();

        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].0, &Key::Integer(1));
        assert_eq!(entries[1].0, &Key::String(b"1".to_vec()));
    }

    #[test]
    fn reads_escapes_and_comments() {
        let value =
            parse_value(b"-- line\n--[==[ long\n]==] {\n[\"a\\110\\\"b\"] = 'c\\td',\n}").unwrap();
        let Value::Table(table) = value else {
            panic!("expected a table");
        };
        let entries: Vec<_> = table.iter().collect();

        assert_eq!(entries[0].0, &Key::String(b"an\"b".to_vec()));
        assert_eq!(entries[0].1, &text("c\td"));
    }

    #[test]
    fn rejects_a_duplicate_key_in_one_table() {
        assert!(matches!(
            parse_value(b"{\n[\"a\"] = 1,\n[\"a\"] = 2,\n}"),
            Err(Error::DuplicateKey(_))
        ));
    }

    #[test]
    fn rejects_trailing_bytes_after_a_value() {
        assert!(matches!(
            parse_value(b"{\n} = 1"),
            Err(Error::Unexpected { .. })
        ));
    }

    #[test]
    fn rejects_a_table_nested_past_the_depth_limit() {
        let mut source = vec![b'{'; 200];
        source.extend(std::iter::repeat_n(b'}', 200));

        assert!(matches!(parse_value(&source), Err(Error::TooDeep(_))));
    }
}
