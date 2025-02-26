DROP SCHEMA IF EXISTS lbaw22131 CASCADE;
CREATE SCHEMA lbaw22131;

SET search_path TO lbaw22131;

-----------------------------------------
-- DOMAINS
-----------------------------------------

CREATE DOMAIN VALID_EMAIL AS TEXT CHECK(VALUE LIKE '_%@_%.__%');

-----------------------------------------
-- TYPES
-----------------------------------------

CREATE TYPE PROPOSED_TOPIC_STATUS AS ENUM ('PENDING', 'ACCEPTED', 'REJECTED');
CREATE TYPE NOTIFICATION_TYPE AS ENUM ('FEEDBACK', 'COMMENT');

-----------------------------------------
-- TABLES
-----------------------------------------

CREATE TABLE authenticated_user(
  id SERIAL PRIMARY KEY, 
  username TEXT NOT NULL, 
  email VALID_EMAIL UNIQUE, 
  date_of_birth TIMESTAMP NOT NULL CHECK (CURRENT_TIMESTAMP >= date_of_birth),
  is_admin BOOLEAN DEFAULT false,
  password TEXT NOT NULL, 
  avatar TEXT, 
  is_suspended BOOLEAN NOT NULL DEFAULT FALSE,
  reputation INTEGER NOT NULL DEFAULT 0
);

-----------------------------------------

CREATE TABLE suspension(
  id SERIAL PRIMARY KEY,
  reason TEXT NOT NULL,
  start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  end_time TIMESTAMP NOT NULL CHECK (end_time >= start_time),
  admin_id INTEGER REFERENCES authenticated_user(id) ON DELETE SET NULL ON UPDATE CASCADE,
  user_id INTEGER NOT NULL REFERENCES authenticated_user(id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT diff_entities CHECK (admin_id != user_id)
);

-----------------------------------------

CREATE TABLE report(
  id SERIAL PRIMARY KEY, 
  reason TEXT NOT NULL, 
  reported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, 
  is_closed BOOLEAN DEFAULT false, 
  reported_id INTEGER NOT NULL REFERENCES authenticated_user(id) ON DELETE CASCADE ON UPDATE CASCADE, 
  reporter_id INTEGER REFERENCES authenticated_user(id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT different_ids CHECK (reporter_id != reported_id)
);

-----------------------------------------

CREATE TABLE topic(
  id SERIAL PRIMARY KEY,
  subject TEXT NOT NULL UNIQUE,
  topic_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status PROPOSED_TOPIC_STATUS NOT NULL DEFAULT 'PENDING',
  user_id INTEGER REFERENCES authenticated_user(id) ON DELETE SET NULL ON UPDATE CASCADE
);

-----------------------------------------

CREATE TABLE follow(
  follower_id INTEGER REFERENCES authenticated_user(id) ON DELETE CASCADE ON UPDATE CASCADE,
  followed_id INTEGER REFERENCES authenticated_user(id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT own_follows CHECK (follower_id != followed_id),
  PRIMARY KEY(follower_id, followed_id)
);

-----------------------------------------

CREATE TABLE post(
  id SERIAL PRIMARY KEY,
  body TEXT NOT NULL,
  published_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  is_edited BOOLEAN DEFAULT false,
  likes INTEGER DEFAULT 0 CHECK (likes >= 0),
  dislikes INTEGER DEFAULT 0 CHECK (dislikes >= 0),
  author_id INTEGER REFERENCES authenticated_user(id) ON DELETE SET NULL ON UPDATE CASCADE
);

-----------------------------------------

CREATE TABLE article(
  post_id INTEGER PRIMARY KEY REFERENCES post(id) ON DELETE CASCADE ON UPDATE CASCADE, 
  title TEXT NOT NULL, 
  thumbnail TEXT
);

-----------------------------------------

CREATE TABLE comment(
  post_id INTEGER PRIMARY KEY REFERENCES post(id) ON DELETE CASCADE ON UPDATE CASCADE,
  article_id INTEGER NOT NULL REFERENCES article(post_id) ON DELETE CASCADE ON UPDATE CASCADE,
  parent_comment_id INTEGER REFERENCES comment(post_id) ON DELETE CASCADE ON UPDATE CASCADE
);

-----------------------------------------

CREATE TABLE feedback(
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES authenticated_user(id) ON DELETE SET NULL ON UPDATE CASCADE, 
  post_id INTEGER NOT NULL REFERENCES post(id) ON DELETE CASCADE ON UPDATE CASCADE, 
  is_like BOOLEAN NOT NULL
);

-----------------------------------------

CREATE TABLE article_topic(
  article_id INTEGER REFERENCES article(post_id) ON DELETE CASCADE ON UPDATE CASCADE,
  topic_id INTEGER REFERENCES topic(id) ON DELETE CASCADE ON UPDATE CASCADE,
  PRIMARY KEY(article_id, topic_id)
);

-----------------------------------------

CREATE TABLE topic_follow(
  user_id INTEGER REFERENCES authenticated_user(id) ON DELETE CASCADE ON UPDATE CASCADE,
  topic_id INTEGER REFERENCES topic(id) ON DELETE CASCADE ON UPDATE CASCADE,
  PRIMARY KEY(user_id, topic_id)
);

-----------------------------------------

CREATE TABLE notification(
  id SERIAL PRIMARY KEY,
  receiver_id INTEGER NOT NULL REFERENCES authenticated_user(id) ON DELETE CASCADE ON UPDATE CASCADE,
  date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, 
  is_read BOOLEAN DEFAULT false,
  fb_giver INTEGER REFERENCES authenticated_user(id) ON DELETE CASCADE ON UPDATE CASCADE,
  rated_post INTEGER REFERENCES post(id) ON DELETE CASCADE ON UPDATE CASCADE,
  new_comment INTEGER REFERENCES comment(post_id) ON DELETE CASCADE ON UPDATE CASCADE,
  type NOTIFICATION_TYPE NOT NULL
);

-----------------------------------------
-- PERFORMANCE INDICES
-----------------------------------------

CREATE INDEX post_author ON post USING hash (author_id);

CREATE INDEX notification_receiver ON notification USING hash (receiver_id);

-----------------------------------------
-- FULL-TEXT SEARCH INDICES
-----------------------------------------

ALTER TABLE article ADD COLUMN tsvectors TSVECTOR;

CREATE FUNCTION article_search_update() RETURNS TRIGGER AS $$
DECLARE new_body text = (select body from post where id = NEW.post_id);
DECLARE old_body text = (select body from post where id = OLD.post_id);
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.tsvectors = (
      setweight(to_tsvector('english', NEW.title), 'A') ||
      setweight(to_tsvector('english', new_body), 'B')
    );
  END IF;

  IF TG_OP = 'UPDATE' THEN
      IF (NEW.title <> OLD.title OR new_body <> old_body) THEN
        NEW.tsvectors = (
          setweight(to_tsvector('english', NEW.title), 'A') ||
          setweight(to_tsvector('english', new_body), 'B')
        );
      END IF;
  END IF;

  RETURN NEW;
END $$
LANGUAGE plpgsql;

CREATE TRIGGER article_search_update
  BEFORE INSERT OR UPDATE ON article
  FOR EACH ROW
  EXECUTE PROCEDURE article_search_update();

CREATE INDEX article_search ON article USING GIST (tsvectors);

-----------------------------------------

ALTER TABLE authenticated_user ADD COLUMN tsvectors TSVECTOR;

CREATE FUNCTION user_search_update() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.tsvectors = (
      setweight(to_tsvector('english', NEW.username), 'A') ||
      setweight(to_tsvector('english', NEW.email), 'B')
    );
  END IF;

  IF TG_OP = 'UPDATE' THEN
      IF (NEW.username <> OLD.username OR NEW.email <> OLD.email) THEN
        NEW.tsvectors = (
          setweight(to_tsvector('english', NEW.username), 'A') ||
          setweight(to_tsvector('english', NEW.email), 'B')
        );
      END IF;
  END IF;

  RETURN NEW;
END $$
LANGUAGE plpgsql;

CREATE TRIGGER user_search_update
  BEFORE INSERT OR UPDATE ON authenticated_user
  FOR EACH ROW
  EXECUTE PROCEDURE user_search_update();

CREATE INDEX user_search ON authenticated_user USING GIST (tsvectors);

-----------------------------------------
-- TRIGGERS
-----------------------------------------

/*
Trigger to update likes/dislikes of a post when feedback is given,
creates a notification on that feedback and updates user reputation.
*/
CREATE FUNCTION feedback_post() RETURNS TRIGGER AS
$BODY$
DECLARE author_id authenticated_user.id%type = (
  SELECT author_id FROM post INNER JOIN authenticated_user ON (post.author_id = authenticated_user.id)
  WHERE post.id = NEW.post_id
);
DECLARE feedback_value INTEGER = 1;
BEGIN
    IF (NOT NEW.is_like)
        THEN feedback_value = -1;
    END IF;

    IF (NEW.is_like) THEN
        UPDATE post SET likes = likes + 1 WHERE id = NEW.post_id;
    ELSE 
        UPDATE post SET dislikes = dislikes + 1 WHERE id = NEW.post_id;
    END IF;
    
    UPDATE authenticated_user SET reputation = reputation + feedback_value
    WHERE id = author_id;

    INSERT INTO notification(receiver_id, is_read, fb_giver, rated_post, new_comment, type)
    VALUES (author_id, FALSE, NEW.user_id, NEW.post_id, NULL, 'FEEDBACK');

    RETURN NULL;
END
$BODY$
LANGUAGE plpgsql;

CREATE TRIGGER feedback_post
    AFTER INSERT ON feedback
    FOR EACH ROW
    EXECUTE PROCEDURE feedback_post();

-----------------------------------------

-- Trigger to remove like/dislike of a post when feedback on it is removed and to update authenticated user reputation.
CREATE FUNCTION remove_feedback() RETURNS TRIGGER AS
$BODY$
DECLARE author_id authenticated_user.id%type = (SELECT author_id FROM post INNER JOIN authenticated_user ON (post.author_id = authenticated_user.id) WHERE post.id = OLD.post_id);
DECLARE feedback_value INTEGER = -1;
BEGIN
    IF (NOT OLD.is_like)
        THEN feedback_value = 1;
    END IF;

    IF (OLD.is_like) THEN
        UPDATE post SET likes = likes - 1 WHERE id = OLD.post_id;
    ELSE 
        UPDATE post SET dislikes = dislikes - 1 WHERE id = OLD.post_id;
    END IF;
    
    UPDATE authenticated_user SET reputation = reputation + feedback_value
    WHERE id = author_id;

    RETURN NULL;
END
$BODY$

LANGUAGE plpgsql;

CREATE TRIGGER remove_feedback
    AFTER DELETE ON feedback
    FOR EACH ROW
    EXECUTE PROCEDURE remove_feedback();

-----------------------------------------

-- Trigger to prevent users from liking or disliking his\her own post (articles or comments)
CREATE FUNCTION check_feedback() RETURNS TRIGGER AS
$BODY$
BEGIN
    IF (NEW.user_id in (
        SELECT post.author_id 
        FROM post 
        WHERE post.id = NEW.post_id)) THEN
            RAISE EXCEPTION 'You cannot give feedback on your own post';
    END IF;
    RETURN NEW;
END;
$BODY$

LANGUAGE plpgsql;

CREATE TRIGGER check_feedback
    BEFORE INSERT ON feedback
    FOR EACH ROW
    EXECUTE PROCEDURE check_feedback();

-----------------------------------------

/*
Trigger to delete all the information about an article that was deleted
it just needs to delete the post represented by that article 
since its that deletion is cascaded to the comments and other elements of the article
*/
CREATE FUNCTION delete_article() RETURNS TRIGGER AS
$BODY$
BEGIN 
    DELETE FROM post WHERE post.id = OLD.post_id;
    RETURN OLD;
END
$BODY$

LANGUAGE plpgsql;

CREATE TRIGGER delete_article
    AFTER DELETE ON article
    FOR EACH ROW
    EXECUTE PROCEDURE delete_article();


-----------------------------------------

/*
Trigger to delete the respective post of a comment when a comment
is deleted. */
CREATE FUNCTION delete_comment() RETURNS TRIGGER AS
$BODY$
BEGIN 
    DELETE FROM post WHERE post.id = OLD.post_id;
    RETURN OLD;
END
$BODY$

LANGUAGE plpgsql;


CREATE TRIGGER delete_comment
    AFTER DELETE ON comment
    FOR EACH ROW
    EXECUTE PROCEDURE delete_comment();

-----------------------------------------

-- Trigger to prevent an article from having an unaccepted topic or more than 3 topics
CREATE FUNCTION add_article_topic_check() RETURNS TRIGGER AS
$BODY$
BEGIN
    IF ((SELECT status FROM topic WHERE NEW.topic_id = topic.id) <> 'ACCEPTED')
    THEN
        RAISE EXCEPTION 'You cannot associate an article to an Unaccepted topic';
    END IF;
    
    IF ((SELECT COUNT(*) FROM article_topic  WHERE article_id = NEW.article_id)) >= 3
    THEN
        RAISE EXCEPTION 'You cannot associate anymore topics to this article';
    END IF;
    RETURN NEW;
END
$BODY$

LANGUAGE plpgsql;

CREATE TRIGGER add_article_topic_check
    BEFORE INSERT ON article_topic  
    FOR EACH ROW
    EXECUTE PROCEDURE add_article_topic_check();

-----------------------------------------

-- Triggers to update the *is_edited* flag when a post's body or an article's title is updated
CREATE FUNCTION set_post_is_edited() RETURNS TRIGGER AS
$BODY$
BEGIN
    UPDATE post SET is_edited = TRUE
    WHERE id = NEW.id;
	RETURN NULL;
END
$BODY$

LANGUAGE plpgsql;

CREATE TRIGGER set_post_is_edited
    AFTER UPDATE ON post
    FOR EACH ROW
    WHEN (OLD.body IS DISTINCT FROM NEW.body)
    EXECUTE PROCEDURE set_post_is_edited();

-----------------------------------------

-- Trigger to mark the post as edited when an article's title is changed
CREATE FUNCTION set_article_is_edited() RETURNS TRIGGER AS
$BODY$
BEGIN
    UPDATE post SET is_edited = TRUE
    WHERE id = NEW.post_id;
	RETURN NULL;
END
$BODY$

LANGUAGE plpgsql;

CREATE TRIGGER set_article_is_edited
    AFTER UPDATE ON article
    FOR EACH ROW
    WHEN (OLD.title IS DISTINCT FROM NEW.title)
    EXECUTE PROCEDURE set_article_is_edited();
  
-----------------------------------------

-- Trigger to put authenticated_user flag to true if a suspension on him is created
CREATE FUNCTION is_suspended_flag_true() RETURNS TRIGGER AS
$BODY$
BEGIN
    UPDATE authenticated_user SET is_suspended = true
    WHERE id = NEW.user_id;
	RETURN NEW;
END
$BODY$

LANGUAGE plpgsql;

CREATE TRIGGER is_suspended_flag_true
    AFTER INSERT ON suspension
    FOR EACH ROW
    EXECUTE PROCEDURE is_suspended_flag_true();


-----------------------------------------

-- Trigger to create a notification when a comment is created

CREATE FUNCTION create_comment_notification() RETURNS TRIGGER AS
$BODY$
DECLARE article_author INTEGER = (
  SELECT author_id FROM post WHERE id = NEW.article_id
);
DECLARE parent_author INTEGER = (
  SELECT author_id FROM post WHERE id = NEW.parent_comment_id
);
BEGIN
  IF parent_author IS NULL THEN
    INSERT INTO notification(receiver_id, is_read, fb_giver, rated_post, new_comment, type) 
        VALUES (article_author, FALSE, NULL, NULL, NEW.post_id, 'COMMENT');
  ELSE
    INSERT INTO notification(receiver_id, is_read, fb_giver, rated_post, new_comment, type) 
        VALUES (parent_author, FALSE, NULL, NULL, NEW.post_id, 'COMMENT');
  END IF;
  RETURN NULL;
END
$BODY$

LANGUAGE plpgsql;
CREATE TRIGGER create_comment_notification
    AFTER INSERT ON comment
    FOR EACH ROW
    EXECUTE PROCEDURE create_comment_notification();

INSERT INTO authenticated_user (username, email, date_of_birth, is_admin, password, avatar, is_suspended, reputation)
VALUES
    ('wilsonedgar', 'angelawarren@gmail.com', TO_TIMESTAMP('1941-01-20', 'YYYY-MM-DD'), False, '9bd8fc89d6aa8b6cc5a412af2e9b98f4', null, False, 516),
    ('aliciagiles', 'gonzalezjose@hotmail.com', TO_TIMESTAMP('1961-12-17', 'YYYY-MM-DD'), False, '4a2ae0b1f2167355b2528711b156982b', null, False, 631),
    ('youngthomas', 'cynthia64@hotmail.com', TO_TIMESTAMP('1967-07-18', 'YYYY-MM-DD'), False, 'f997b0f751f8bf4008536c6a5870efd1', null, False, 826),
    ('collinstanya', 'prestonhuff@hotmail.com', TO_TIMESTAMP('1944-06-09', 'YYYY-MM-DD'), False, '847d913369818e9da39e5783a89c2f53', null, False, 715),
    ('mccallbrian', 'anthonyross@gmail.com', TO_TIMESTAMP('1912-05-18', 'YYYY-MM-DD'), False, '6566d27d344f200a5c554f0632ebbacf', null, False, 26),
    ('gwhite', 'mhaney@hotmail.com', TO_TIMESTAMP('1955-10-19', 'YYYY-MM-DD'), False, '469c6b97a601ccbee7981e3a0f63ead2', null, False, -99),
    ('rodriguezjoseph', 'michaelschultz@hotmail.com', TO_TIMESTAMP('1973-05-01', 'YYYY-MM-DD'), False, 'b317367df06f75fc70de2a441750d92a', null, False, 420),
    ('rosesamuel', 'mwilliamson@gmail.com', TO_TIMESTAMP('1956-05-10', 'YYYY-MM-DD'), False, 'f5a21f5ba9e4769e5bb65300a871efec', null, False, 678),
    ('derrick06', 'mrivera@hotmail.com', TO_TIMESTAMP('2005-02-23', 'YYYY-MM-DD'), False, '42593cdba1ea4ae98fd28ce7c09eba75', null, False, 859),
    ('cassandracalderon', 'bondkristen@yahoo.com', TO_TIMESTAMP('1972-12-27', 'YYYY-MM-DD'), False, 'c5f195a014d9a382bfac4fa35b0cabfd', null, False, 136),
    ('igiles', 'samuel05@gmail.com', TO_TIMESTAMP('1958-12-31', 'YYYY-MM-DD'), False, '619962a6eda46825878e5b77272e86a7', null, False, 347),
    ('anthonykim', 'hlee@gmail.com', TO_TIMESTAMP('1996-04-25', 'YYYY-MM-DD'), False, 'f6f9d833e471f5bfe3f9a5d4f5da4fec', null, False, 319),
    ('johnwaters', 'jamesbarron@yahoo.com', TO_TIMESTAMP('1921-08-23', 'YYYY-MM-DD'), False, '33391a9226ddc34cc7c9ecf4dc6a5b46', null, False, -54),
    ('danielle24', 'qfoster@gmail.com', TO_TIMESTAMP('1950-07-10', 'YYYY-MM-DD'), False, '932cc9fc81b3a678a09100e150cd94dd', null, False, 202),
    ('ideleon', 'amandawilliams@gmail.com', TO_TIMESTAMP('1955-11-24', 'YYYY-MM-DD'), False, 'e711eaba7e42d052f123c1b9b0609a51', null, False, 782);

/* create admin user and suspended user*/
INSERT INTO authenticated_user (username, email, date_of_birth, is_admin, password, avatar, is_suspended, reputation)
VALUES
  ('admin1', 'admin1@lbaw.com', TO_TIMESTAMP('1998-12-03', 'YYYY-MM-DD'), True, '$2a$12$L1ZZNfOm63yL5kYDYOVv7OUbHodZSAJjgW9b9Z6/GiB4anaR.FLM6', null, False, 666),
  ('admin2', 'admin2@lbaw.com', TO_TIMESTAMP('1998-12-04', 'YYYY-MM-DD'), True, '$2a$12$L1ZZNfOm63yL5kYDYOVv7OUbHodZSAJjgW9b9Z6/GiB4anaR.FLM6', null, False, 999),
  ('suspended1', 'suspended1@lbaw.com', TO_TIMESTAMP('1998-01-01', 'YYYY-MM-DD'), False, '$2a$12$L1ZZNfOm63yL5kYDYOVv7OUbHodZSAJjgW9b9Z6/GiB4anaR.FLM6', null, True, -666),
  ('suspended2', 'suspended2@lbaw.com', TO_TIMESTAMP('1998-02-02', 'YYYY-MM-DD'), False, '$2a$12$L1ZZNfOm63yL5kYDYOVv7OUbHodZSAJjgW9b9Z6/GiB4anaR.FLM6', null, True, -999),
  ('npc', 'npc@lbaw.com', TO_TIMESTAMP('1997-02-02', 'YYYY-MM-DD'), False, '$2a$12$L1ZZNfOm63yL5kYDYOVv7OUbHodZSAJjgW9b9Z6/GiB4anaR.FLM6', null, False, 404);

INSERT INTO suspension (reason, start_time, end_time, admin_id, user_id)
VALUES
    ('nsfw profile pic and comments', TO_TIMESTAMP('2022-03-23', 'YYYY-MM-DD'), TO_TIMESTAMP('2025-10-19', 'YYYY-MM-DD'), 16,19),
    ('Threatening another user', TO_TIMESTAMP('2023-03-23', 'YYYY-MM-DD'), TO_TIMESTAMP('2025-08-07', 'YYYY-MM-DD'),17,18);

INSERT INTO report (reason, reported_at, is_closed, reported_id, reporter_id)
VALUES
    ('Toxic person', TO_TIMESTAMP('2021-04-21', 'YYYY-MM-DD'), True, 4,3),
    ('Disrespectful towards my culture', TO_TIMESTAMP('2021-08-11', 'YYYY-MM-DD'), True, 13,8),
    ('Promoting another website', TO_TIMESTAMP('2022-09-11', 'YYYY-MM-DD'), True, 8,10),
    ('Offensive profile picture', TO_TIMESTAMP('2021-12-26', 'YYYY-MM-DD'), True, 6,3),
    ('Hate attitude on comment section', TO_TIMESTAMP('2020-10-30', 'YYYY-MM-DD'), True, 14,4),
    ('He told me he would find me and kill me', TO_TIMESTAMP('2021-10-19', 'YYYY-MM-DD'), True, 11,12),
    ('NSFW profile picture and comments', TO_TIMESTAMP('2021-08-19', 'YYYY-MM-DD'), True, 6,12),
    ('I dont like this person', TO_TIMESTAMP('2021-07-19', 'YYYY-MM-DD'), True, 15,8),
    ('Kick her out of this website please', TO_TIMESTAMP('2021-11-30', 'YYYY-MM-DD'), False, 3,4),
    ('Told me to oof myself', TO_TIMESTAMP('2021-01-24', 'YYYY-MM-DD'), True, 13,4);

INSERT INTO topic (subject, topic_date, status, user_id)
VALUES
    ('Sports', TO_TIMESTAMP('2021-10-03', 'YYYY-MM-DD'), 'ACCEPTED',1),
    ('Movies', TO_TIMESTAMP('2022-07-01', 'YYYY-MM-DD'), 'ACCEPTED',2),
    ('Anime', TO_TIMESTAMP('2021-01-20', 'YYYY-MM-DD'), 'ACCEPTED',3),
    ('Crime', TO_TIMESTAMP('2020-12-31', 'YYYY-MM-DD'), 'REJECTED',4),
    ('Health', TO_TIMESTAMP('2022-04-09', 'YYYY-MM-DD'), 'ACCEPTED',5),
    ('Science', TO_TIMESTAMP('2022-07-01', 'YYYY-MM-DD'), 'ACCEPTED',6),
    ('Fights', TO_TIMESTAMP('2022-08-05', 'YYYY-MM-DD'), 'ACCEPTED',7),
    ('Religion', TO_TIMESTAMP('2022-06-26', 'YYYY-MM-DD'), 'ACCEPTED',8),
    ('Law', TO_TIMESTAMP('2021-02-24', 'YYYY-MM-DD'), 'ACCEPTED',9),
    ('Games', TO_TIMESTAMP('2021-10-01', 'YYYY-MM-DD'), 'PENDING',10);

INSERT INTO follow (follower_id, followed_id)
VALUES
    (1,2),
    (2,1),
    (3,4),
    (4,5),
    (2,3),
    (3,1),
    (14,12),
    (15,11),
    (8,9),
    (9,1),
    (6,2),
    (1,16),
    (2,16),
    (3,16),
    (4,16),
    (5,17),
    (6,17),
    (7,17),
    (8,17);

INSERT INTO post (body, published_date, is_edited, likes, dislikes, author_id)
VALUEs
    ('This match had been billed as Kylian Mbappé vs. Messi  the 23-year-old French star ready to assume the mantle of the worlds greatest player from his 35-year-old Paris Saint-Germain teammate.', TO_TIMESTAMP('2022-12-18', 'YYYY-MM-DD'), False, 54, 75, 1),
    ('Fall and winter are associated with a higher incidence of upper respiratory infections, such as the common cold and flu, due to the increased transmission of respiratory viruses.
    Although cooler temperatures and low humidity are associated with increased susceptibility to respiratory viruses, the biological mechanisms underlying this relationship are not understood.
    A recent study showed that cold temperatures lead to a decline in the immune response elicited by cells in the nasal cavity to viruses, which explains why people are more susceptible to upper respiratory infections in colder temperatures.', TO_TIMESTAMP('2022-10-10', 'YYYY-MM-DD'), False, 12, 2, 3),
    ('The way of water connects all things. The sea is our home before our birth and after we die.” Beyond the 3D visual spectacle that Avatar is, something we trust James Cameron to deliver, the franchises beauty lies in its underlying spiritual arc and ode to continuity of life. Life finds a way. It evolves no matter the surroundings as love is transformative.
    Humans call the Navi hostiles and insurgents, when it is they who forcefully infiltrate and occupy their land. Despite its magical, fictional setting, Avatar is not devoid of socio-political themes. It addresses race, civilisation, takes a strong anti-military stand and makes a plea for environment conservation through its simple story of parents and children. A spectacular climax revolves around parents protecting their children and vice versa.
    From lush jungles to the gorgeous reefs… the action shifts from forests to the sea this time around and its equally meditative and hypnotic. For over three hours you find yourself immersed in the enchanting world of an oceanic clan (Metkayina) or the reef people who give Sully and his family a refuge from humans. The sequel scores high on action and emotion. One is not compromised for the other. Happiness is simple. The Sullys stay together. This is our biggest weakness and our greatest strength,” says Jake Sully and the story embodies that spirit. The tale isnt unique per se but the storytelling and visual excellence are otherworldly epic. Mounted on a massive scale, not once do you find yourself wanting to return to the real world
    While the predecessor set the bar high for visual effects 13 years ago, the new film takes it a step further. Like the previous film, the director does not use 3D as a gimmick but uses it artfully to accentuate audience immersion in the world and story. Avatar: The Way of Water deserves be watched in IMAX 3D. It is the greatest immersive cinema experience of the year — world building at its finest.', TO_TIMESTAMP('2022-10-04', 'YYYY-MM-DD'), False, 51, 16, 2),
    ('If you think religion belongs to the past and we live in a new age of reason, you need to check out the facts: 84% of the worlds population identifies with a religious group. Members of this demographic are generally younger and produce more children than those who have no religious affiliation, so the world is getting more religious, not less  although there are significant geographical variations.', TO_TIMESTAMP('2018-08-27', 'YYYY-MM-DD'), False, 72, 76, 6),
    ('Of conception. Sea, Tasman Sea, and Mediterranean', TO_TIMESTAMP('1945-03-22', 'YYYY-MM-DD'), False, 34, 70, 11),
    ('(the Internet body temperature', TO_TIMESTAMP('1987-08-26', 'YYYY-MM-DD'), False, 13, 40, 13),
    ('Crossed from or low-pressure', TO_TIMESTAMP('2014-11-18', 'YYYY-MM-DD'), False, 61, 5, 9),
    ('(corn and Montana, which has eleven judges appointed by the crown and the', TO_TIMESTAMP('1938-12-02', 'YYYY-MM-DD'), False, 9, 31, 13);

INSERT INTO article (post_id, title, thumbnail) 
VALUES
    (1, 'The clashing of two stars', null),
    (2, 'Why do we always seem to catch a cold or flu in cold weather? A new study explains', null),
    (3, 'Avatar: The Way Of Water Movie Review : A worthy sequel', null),
    (4, 'Religion: why faith is becoming more and more popular', null);

INSERT INTO feedback (user_id, post_id, is_like)
VALUES
    (1,2,True),
    (2,5,False),
    (6,1,True),
    (7,3, True),
    (14, 4, False);

INSERT INTO article_topic(article_id, topic_id)
VALUES
    (1,1),
    (2,5),
    (3,2),
    (4,8);

INSERT INTO topic_follow(user_id, topic_id)
VALUES
  (1,1),
  (1,2),
  (17,1);