{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-|
Module      : Text.Jira.Parser.Inline
Copyright   : © 2019 Albert Krewinkel
License     : MIT

Maintainer  : Albert Krewinkel <tarleb@zeitkraut.de>
Stability   : alpha
Portability : portable

Parse Jira wiki inline markup.
-}

module Text.Jira.Parser.Inline
  ( inline
    -- * Inline component parsers
  , anchor
  , emoji
  , entity
  , image
  , linebreak
  , link
  , monospaced
  , str
  , styled
  , symbol
  , whitespace
  ) where

import Control.Monad (guard, void)
import Data.Char (isLetter, isPunctuation)
#if !MIN_VERSION_base(4,13,0)
import Data.Monoid ((<>), All (..))
#else
import Data.Monoid (All (..))
#endif
import Data.Text (pack)
import Text.Jira.Markup
import Text.Jira.Parser.Core
import Text.Parsec

-- | Parses any inline element.
inline :: JiraParser Inline
inline = notFollowedBy' blockEnd *> choice
  [ whitespace
  , emoji
  , str
  , linebreak
  , link
  , image
  , styled
  , monospaced
  , anchor
  , entity
  , symbol
  ] <?> "inline"
  where
    blockEnd = char '{' *> choice (map string blockNames) <* char '}'

-- | Characters with a special meaning, i.e., those used for markup.
specialChars :: String
specialChars = " \n" ++ symbolChars

-- | Special characters which can be part of a string.
symbolChars :: String
symbolChars = "_+-*^~|[]{}(!&\\"

-- | Parses an in-paragraph newline as a @Linebreak@ element. Both newline
-- characters and double-backslash are recognized as line-breaks.
linebreak :: JiraParser Inline
linebreak = Linebreak <$ try (
  choice [ void $ newline <* notFollowedBy' endOfPara
         , void $ string "\\\\" <* notFollowedBy' (char '\\')
         ]
  ) <?> "linebreak"

-- | Parses whitespace and return a @Space@ element.
whitespace :: JiraParser Inline
whitespace = Space <$ skipMany1 (char ' ') <?> "whitespace"

-- | Parses a simple, markup-less string into a @Str@ element.
str :: JiraParser Inline
str = Str . pack <$> (alphaNums <|> otherNonSpecialChars) <?> "string"
  where
    alphaNums = many1 alphaNum <* updateLastStrPos
    otherNonSpecialChars = many1 (noneOf specialChars)

-- | Parses an HTML entity into an @'Entity'@ element.
entity :: JiraParser Inline
entity = Entity . pack
  <$> try (char '&' *> (numerical <|> named) <* char ';')
  where
    numerical = (:) <$> char '#' <*> many1 digit
    named = many1 letter

-- | Parses textual representation of an icon into an @'Emoji'@ element.
emoji :: JiraParser Inline
emoji = Emoji <$> (smiley <|> icon) <* notFollowedBy' letter <?> "emoji"
  where
    smiley = try $ choice
      [ IconWinking <$ string ";)"
      , char ':' *> anyChar >>= \case
          'D' -> pure IconSmiling
          ')' -> pure IconSlightlySmiling
          '(' -> pure IconFrowning
          'P' -> pure IconTongue
          c   -> fail ("unknown smiley: :" ++ [c])
      ]

    icon = try $ do
      let isIconChar c = isLetter c || (c `elem` ("/!+-?*" :: String))
      name <- char '('
              *> many1 (satisfy isIconChar)
              <* char ')'
      case name of
        "y"       -> pure IconThumbsUp
        "n"       -> pure IconThumbsDown
        "i"       -> pure IconInfo
        "/"       -> pure IconCheckmark
        "x"       -> pure IconX
        "!"       -> pure IconAttention
        "+"       -> pure IconPlus
        "-"       -> pure IconMinus
        "?"       -> pure IconQuestionmark
        "on"      -> pure IconOn
        "off"     -> pure IconOff
        "*"       -> pure IconStar
        "*r"      -> pure IconStarRed
        "*g"      -> pure IconStarGreen
        "*b"      -> pure IconStarBlue
        "*y"      -> pure IconStarYellow
        "flag"    -> pure IconFlag
        "flagoff" -> pure IconFlagOff
        _         -> fail ("not a known emoji" <> name)

-- | Parses a special character symbol as a @Str@.
symbol :: JiraParser Inline
symbol = SpecialChar <$> (escapedChar <|> symbolChar)
  <?> "symbol"
  where
    escapedChar = try (char '\\' *> satisfy isPunctuation)

    symbolChar = do
      inTablePred <- do
        b <- stateInTable <$> getState
        return $ if b then All . (/= '|') else mempty
      inLinkPred  <- do
        b <- stateInLink  <$> getState
        return $ if b then All . (`notElem` ("]|\n" :: String)) else mempty
      oneOf $ filter (getAll . (inTablePred <> inLinkPred)) symbolChars


--
-- Anchors, links and images
--

-- | Parses an anchor into an @Anchor@ element.
anchor :: JiraParser Inline
anchor = Anchor . pack . filter (/= ' ')
  <$> try (string "{anchor:" *> noneOf "\n" `manyTill` char '}')

-- | Parse image into an @Image@ element.
image :: JiraParser Inline
image = fmap (Image . URL . pack) . try $
  char '!' *> noneOf "\r\t\n" `manyTill` char '!'

-- | Parse link into a @Link@ element.
link :: JiraParser Inline
link = try $ do
  guard . not . stateInLink =<< getState
  withStateFlag (\b st -> st { stateInLink = b }) $ do
    _ <- char '['
    alias <- option [] $ try (many inline <* char '|')
    url   <- URL . pack <$> many1 (noneOf "|] \n")
    _ <- char ']'
    return $ Link alias url

--
-- Markup
--

-- | Parses styled text
styled :: JiraParser Inline
styled = try $ do
  delim <- lookAhead $ oneOf "-_+*~^"
  content <- delim `delimitingMany` inline
  let style = delimiterStyle delim
  return $ Styled style content

-- | Returns the markup kind from the delimiting markup character.
delimiterStyle :: Char -> InlineStyle
delimiterStyle = \case
  '*' -> Strong
  '+' -> Insert
  '-' -> Strikeout
  '^' -> Superscript
  '_' -> Emphasis
  '~' -> Subscript
  c   -> error ("Unknown delimiter character: " ++ [c])

-- | Parses monospaced text into @Monospaced@.
monospaced :: JiraParser Inline
monospaced = Monospaced
  <$> enclosed (try $ string "{{") (try $ string "}}") inline
  <?> "monospaced"

--
-- Helpers
--

-- | Parse text delimited by a character.
delimitingMany :: Char -> JiraParser a -> JiraParser [a]
delimitingMany c = enclosed (char c) (char c)

enclosed :: JiraParser opening -> JiraParser closing
         -> JiraParser a
         -> JiraParser [a]
enclosed opening closing parser = try $ do
  guard =<< notAfterString
  opening *> notFollowedBy space *> manyTill parser closing'
  where
    closing' = try $ closing <* lookAhead wordBoundary
    wordBoundary = void (satisfy (not . isLetter)) <|> eof
