-- =====================================================================
-- БД для ИС «Книжного фонда и работы библиотеки»  (СУБД: SQLite 3)
-- =====================================================================
PRAGMA foreign_keys = ON;

DROP VIEW    IF EXISTS v_overdue_loans;
DROP VIEW    IF EXISTS v_book_availability;
DROP VIEW    IF EXISTS v_reader_history;
DROP TRIGGER IF EXISTS trg_loan_before_insert;
DROP TRIGGER IF EXISTS trg_loan_after_insert;
DROP TRIGGER IF EXISTS trg_loan_after_return;
DROP TABLE   IF EXISTS fine;
DROP TABLE   IF EXISTS loan;
DROP TABLE   IF EXISTS book_copy;
DROP TABLE   IF EXISTS book_author;
DROP TABLE   IF EXISTS book;
DROP TABLE   IF EXISTS employee;
DROP TABLE   IF EXISTS reader;
DROP TABLE   IF EXISTS department;
DROP TABLE   IF EXISTS genre;
DROP TABLE   IF EXISTS publisher;
DROP TABLE   IF EXISTS author;

-- ---------------------------------------------------------------------
-- 1. ТАБЛИЦЫ
-- ---------------------------------------------------------------------

-- Автор
CREATE TABLE author (
    author_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    last_name   TEXT NOT NULL,
    first_name  TEXT NOT NULL,
    middle_name TEXT,
    birth_year  INTEGER CHECK (birth_year BETWEEN 1000 AND 2100)
);

-- Издательство
CREATE TABLE publisher (
    publisher_id INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL UNIQUE,
    city         TEXT
);

-- Жанр / раздел литературы
CREATE TABLE genre (
    genre_id INTEGER PRIMARY KEY AUTOINCREMENT,
    name     TEXT NOT NULL UNIQUE
);

-- Отдел библиотеки (абонемент, читальный зал, ...)
CREATE TABLE department (
    department_id INTEGER PRIMARY KEY AUTOINCREMENT,
    name          TEXT NOT NULL UNIQUE,
    can_take_home INTEGER NOT NULL DEFAULT 1 CHECK (can_take_home IN (0,1))
);

-- Книга (издание): библиографическое описание
CREATE TABLE book (
    book_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT NOT NULL,
    isbn         TEXT UNIQUE,
    publish_year INTEGER CHECK (publish_year BETWEEN 1400 AND 2100),
    pages        INTEGER CHECK (pages > 0),
    publisher_id INTEGER NOT NULL REFERENCES publisher(publisher_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    genre_id     INTEGER NOT NULL REFERENCES genre(genre_id)         ON UPDATE CASCADE ON DELETE RESTRICT
);

-- Связь «книга — автор» (M:N)
CREATE TABLE book_author (
    book_id   INTEGER NOT NULL REFERENCES book(book_id)     ON UPDATE CASCADE ON DELETE CASCADE,
    author_id INTEGER NOT NULL REFERENCES author(author_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    PRIMARY KEY (book_id, author_id)
);

-- Экземпляр книги (физическая единица фонда)
CREATE TABLE book_copy (
    copy_id            INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id            INTEGER NOT NULL REFERENCES book(book_id)             ON UPDATE CASCADE ON DELETE RESTRICT,
    department_id      INTEGER NOT NULL REFERENCES department(department_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    inventory_number   TEXT NOT NULL UNIQUE,
    status             TEXT NOT NULL DEFAULT 'available'
                       CHECK (status IN ('available','issued','written_off','lost')),
    acquisition_date   TEXT NOT NULL DEFAULT (date('now')),
    price              REAL CHECK (price >= 0)
);

-- Читатель
CREATE TABLE reader (
    reader_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    card_number       TEXT NOT NULL UNIQUE,          -- № читательского билета
    last_name         TEXT NOT NULL,
    first_name        TEXT NOT NULL,
    middle_name       TEXT,
    birth_date        TEXT,
    phone             TEXT,
    email             TEXT,
    address           TEXT,
    registration_date TEXT NOT NULL DEFAULT (date('now')),
    is_active         INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1))
);

-- Сотрудник (библиотекарь)
CREATE TABLE employee (
    employee_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    last_name     TEXT NOT NULL,
    first_name    TEXT NOT NULL,
    middle_name   TEXT,
    position      TEXT NOT NULL,
    department_id INTEGER REFERENCES department(department_id) ON UPDATE CASCADE ON DELETE SET NULL,
    hire_date     TEXT NOT NULL DEFAULT (date('now')),
    phone         TEXT
);

-- Выдача книги читателю
CREATE TABLE loan (
    loan_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    copy_id     INTEGER NOT NULL REFERENCES book_copy(copy_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    reader_id   INTEGER NOT NULL REFERENCES reader(reader_id)  ON UPDATE CASCADE ON DELETE RESTRICT,
    employee_id INTEGER NOT NULL REFERENCES employee(employee_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    issue_date  TEXT NOT NULL DEFAULT (date('now')),
    due_date    TEXT NOT NULL,                       -- срок возврата
    return_date TEXT,                                -- NULL = ещё на руках
    CHECK (due_date >= issue_date),
    CHECK (return_date IS NULL OR return_date >= issue_date)
);

-- Штраф за просрочку / порчу
CREATE TABLE fine (
    fine_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    loan_id   INTEGER NOT NULL REFERENCES loan(loan_id) ON UPDATE CASCADE ON DELETE CASCADE,
    amount    REAL NOT NULL CHECK (amount > 0),
    reason    TEXT NOT NULL,
    fine_date TEXT NOT NULL DEFAULT (date('now')),
    is_paid   INTEGER NOT NULL DEFAULT 0 CHECK (is_paid IN (0,1))
);

-- Индексы для частых запросов
CREATE INDEX idx_book_title       ON book(title);
CREATE INDEX idx_book_publisher   ON book(publisher_id);
CREATE INDEX idx_book_genre       ON book(genre_id);
CREATE INDEX idx_copy_book        ON book_copy(book_id);
CREATE INDEX idx_copy_status      ON book_copy(status);
CREATE INDEX idx_loan_reader      ON loan(reader_id);
CREATE INDEX idx_loan_copy        ON loan(copy_id);
CREATE INDEX idx_loan_return      ON loan(return_date);
CREATE INDEX idx_reader_lastname  ON reader(last_name);

-- ---------------------------------------------------------------------
-- 2. ТРИГГЕРЫ (автоматический учёт статуса экземпляра)
-- ---------------------------------------------------------------------

-- Нельзя выдать экземпляр, которого нет в наличии
CREATE TRIGGER trg_loan_before_insert
BEFORE INSERT ON loan
WHEN NEW.return_date IS NULL
BEGIN
    SELECT RAISE(ABORT, 'Экземпляр недоступен для выдачи')
    WHERE (SELECT status FROM book_copy WHERE copy_id = NEW.copy_id) <> 'available';
    SELECT RAISE(ABORT, 'Читатель заблокирован')
    WHERE (SELECT is_active FROM reader WHERE reader_id = NEW.reader_id) = 0;
END;

-- После выдачи: экземпляр -> «выдан»
CREATE TRIGGER trg_loan_after_insert
AFTER INSERT ON loan
WHEN NEW.return_date IS NULL
BEGIN
    UPDATE book_copy SET status = 'issued' WHERE copy_id = NEW.copy_id;
END;

-- После возврата: экземпляр -> «в наличии»
CREATE TRIGGER trg_loan_after_return
AFTER UPDATE OF return_date ON loan
WHEN OLD.return_date IS NULL AND NEW.return_date IS NOT NULL
BEGIN
    UPDATE book_copy SET status = 'available'
    WHERE copy_id = NEW.copy_id AND status = 'issued';
END;

-- ---------------------------------------------------------------------
-- 3. ПРЕДСТАВЛЕНИЯ
-- ---------------------------------------------------------------------

-- Книги с авторами и количеством свободных экземпляров
CREATE VIEW v_book_availability AS
SELECT b.book_id,
       b.title,
       (SELECT group_concat(a.last_name || ' ' || substr(a.first_name,1,1) || '.', ', ')
          FROM book_author ba JOIN author a ON a.author_id = ba.author_id
         WHERE ba.book_id = b.book_id)                                      AS authors,
       COUNT(c.copy_id)                                                     AS total_copies,
       SUM(CASE WHEN c.status = 'available' THEN 1 ELSE 0 END)              AS available_copies
FROM book b
LEFT JOIN book_copy c ON c.book_id = b.book_id
GROUP BY b.book_id, b.title;

-- Просроченные выдачи (на сегодня)
CREATE VIEW v_overdue_loans AS
SELECT l.loan_id,
       r.card_number,
       r.last_name || ' ' || r.first_name AS reader,
       r.phone,
       b.title,
       c.inventory_number,
       l.issue_date,
       l.due_date,
       CAST(julianday(date('now')) - julianday(l.due_date) AS INTEGER) AS days_overdue
FROM loan l
JOIN reader    r ON r.reader_id = l.reader_id
JOIN book_copy c ON c.copy_id   = l.copy_id
JOIN book      b ON b.book_id   = c.book_id
WHERE l.return_date IS NULL AND l.due_date < date('now');

-- История выдач читателей
CREATE VIEW v_reader_history AS
SELECT r.reader_id,
       r.last_name || ' ' || r.first_name AS reader,
       b.title,
       l.issue_date,
       l.due_date,
       l.return_date,
       e.last_name AS librarian
FROM loan l
JOIN reader    r ON r.reader_id   = l.reader_id
JOIN book_copy c ON c.copy_id     = l.copy_id
JOIN book      b ON b.book_id     = c.book_id
JOIN employee  e ON e.employee_id = l.employee_id;

-- ---------------------------------------------------------------------
-- 4. ТЕСТОВЫЕ ДАННЫЕ
-- ---------------------------------------------------------------------

INSERT INTO author (last_name, first_name, middle_name, birth_year) VALUES
 ('Толстой',     'Лев',       'Николаевич',   1828),  -- 1
 ('Достоевский', 'Фёдор',     'Михайлович',   1821),  -- 2
 ('Пушкин',      'Александр', 'Сергеевич',    1799),  -- 3
 ('Булгаков',    'Михаил',    'Афанасьевич',  1891),  -- 4
 ('Чехов',       'Антон',     'Павлович',     1860),  -- 5
 ('Стругацкий',  'Аркадий',   'Натанович',    1925),  -- 6
 ('Стругацкий',  'Борис',     'Натанович',    1933),  -- 7
 ('Мартин',      'Роберт',    NULL,           1952),  -- 8
 ('Таненбаум',   'Эндрю',     NULL,           1944),  -- 9
 ('Дейт',        'Кристофер', NULL,           1941),  -- 10
 ('Керниган',    'Брайан',    NULL,           1942),  -- 11
 ('Ритчи',       'Деннис',    NULL,           1941);  -- 12

INSERT INTO publisher (name, city) VALUES
 ('Эксмо',     'Москва'),           -- 1
 ('АСТ',       'Москва'),           -- 2
 ('Азбука',    'Санкт-Петербург'),  -- 3
 ('Питер',     'Санкт-Петербург'),  -- 4
 ('Диалектика','Москва');           -- 5

INSERT INTO genre (name) VALUES
 ('Роман'),                 -- 1
 ('Поэзия'),                -- 2
 ('Пьеса'),                 -- 3
 ('Фантастика'),            -- 4
 ('Повесть'),               -- 5
 ('Компьютерная литература'); -- 6

INSERT INTO department (name, can_take_home) VALUES
 ('Абонемент',                 1),  -- 1
 ('Читальный зал',             0),  -- 2
 ('Отдел научной литературы',  1);  -- 3

INSERT INTO book (title, isbn, publish_year, pages, publisher_id, genre_id) VALUES
 ('Война и мир',                        '978-5-04-100001-1', 2020, 1274, 1, 1),  -- 1
 ('Анна Каренина',                      '978-5-04-100002-8', 2019,  864, 1, 1),  -- 2
 ('Преступление и наказание',           '978-5-17-100003-5', 2021,  608, 2, 1),  -- 3
 ('Идиот',                              '978-5-17-100004-2', 2018,  640, 2, 1),  -- 4
 ('Евгений Онегин',                     '978-5-38-900005-9', 2020,  320, 3, 2),  -- 5
 ('Капитанская дочка',                  '978-5-38-900006-6', 2019,  256, 3, 5),  -- 6
 ('Мастер и Маргарита',                 '978-5-17-100007-3', 2022,  480, 2, 1),  -- 7
 ('Собачье сердце',                     '978-5-17-100008-0', 2021,  192, 2, 5),  -- 8
 ('Вишнёвый сад',                       '978-5-04-100009-4', 2017,  128, 1, 3),  -- 9
 ('Пикник на обочине',                  '978-5-17-100010-6', 2020,  224, 2, 4),  -- 10
 ('Трудно быть богом',                  '978-5-17-100011-3', 2019,  256, 2, 4),  -- 11
 ('Чистый код',                         '978-5-49-600012-1', 2022,  464, 4, 6),  -- 12
 ('Современные операционные системы',   '978-5-49-600013-8', 2021, 1120, 4, 6),  -- 13
 ('Введение в системы баз данных',      '978-5-84-590014-5', 2019, 1328, 5, 6),  -- 14
 ('Язык программирования C',            '978-5-84-590015-2', 2020,  288, 5, 6);  -- 15

INSERT INTO book_author (book_id, author_id) VALUES
 (1,1),(2,1),(3,2),(4,2),(5,3),(6,3),(7,4),(8,4),(9,5),
 (10,6),(10,7),(11,6),(11,7),
 (12,8),(13,9),(14,10),(15,11),(15,12);

-- Экземпляры (все «в наличии», статус изменят триггеры при выдаче)
INSERT INTO book_copy (book_id, department_id, inventory_number, acquisition_date, price) VALUES
 (1, 1,'INV-0001','2021-02-10', 890),
 (1, 2,'INV-0002','2021-02-10', 890),
 (2, 1,'INV-0003','2021-02-10', 750),
 (3, 1,'INV-0004','2022-03-15', 520),
 (3, 1,'INV-0005','2022-03-15', 520),
 (4, 1,'INV-0006','2020-09-01', 480),
 (5, 1,'INV-0007','2021-09-01', 350),
 (5, 2,'INV-0008','2021-09-01', 350),
 (6, 1,'INV-0009','2020-09-01', 300),
 (7, 1,'INV-0010','2023-01-20', 610),
 (7, 1,'INV-0011','2023-01-20', 610),
 (7, 2,'INV-0012','2023-01-20', 610),
 (8, 1,'INV-0013','2022-03-15', 280),
 (9, 1,'INV-0014','2019-10-05', 220),
 (10,1,'INV-0015','2022-06-11', 340),
 (10,1,'INV-0016','2022-06-11', 340),
 (11,1,'INV-0017','2021-11-30', 360),
 (12,3,'INV-0018','2023-04-02',1450),
 (12,3,'INV-0019','2023-04-02',1450),
 (13,3,'INV-0020','2022-10-10',2100),
 (14,3,'INV-0021','2021-05-18',2350),
 (14,2,'INV-0022','2021-05-18',2350),
 (15,3,'INV-0023','2022-02-25',1100),
 (15,3,'INV-0024','2022-02-25',1100);

INSERT INTO reader (card_number, last_name, first_name, middle_name, birth_date, phone, email, address, registration_date) VALUES
 ('R-0001','Иванов',   'Алексей',  'Петрович',    '2003-04-12','+7 902 111-22-01','ivanov@mail.ru',   'г. Ульяновск, ул. Гончарова, 10-5',  '2022-09-01'),
 ('R-0002','Петрова',  'Мария',    'Сергеевна',   '2004-11-03','+7 902 111-22-02','petrova@mail.ru',  'г. Ульяновск, пр. Гая, 45-12',       '2022-09-01'),
 ('R-0003','Сидоров',  'Дмитрий',  'Андреевич',   '2002-07-25','+7 902 111-22-03','sidorov@mail.ru',  'г. Ульяновск, ул. Минаева, 7-33',    '2022-09-05'),
 ('R-0004','Козлова',  'Анна',     'Игоревна',    '2005-01-19','+7 902 111-22-04','kozlova@mail.ru',  'г. Ульяновск, ул. Рябикова, 91-8',   '2023-09-01'),
 ('R-0005','Морозов',  'Никита',   'Олегович',    '2004-05-30','+7 902 111-22-05','morozov@mail.ru',  'г. Ульяновск, ул. Врача Сурова, 3-2','2023-09-01'),
 ('R-0006','Волкова',  'Екатерина','Дмитриевна',  '2003-12-08','+7 902 111-22-06','volkova@mail.ru',  'г. Ульяновск, ул. Хрустальная, 22-14','2023-09-04'),
 ('R-0007','Новиков',  'Артём',    'Владимирович','2001-02-14','+7 902 111-22-07','novikov@mail.ru',  'г. Ульяновск, ул. Локомотивная, 5-1','2021-09-01'),
 ('R-0008','Фёдорова', 'Ольга',    'Николаевна',  '1985-06-21','+7 902 111-22-08','fedorova@mail.ru', 'г. Ульяновск, ул. Наганова, 60-40',  '2020-02-17'),
 ('R-0009','Соколов',  'Павел',    'Ильич',       '2004-09-09','+7 902 111-22-09','sokolov@mail.ru',  'г. Ульяновск, ул. Отрадная, 18-9',   '2024-09-02'),
 ('R-0010','Лебедева', 'Ксения',   'Александровна','2005-03-27','+7 902 111-22-10','lebedeva@mail.ru','г. Ульяновск, пр. Ленинского Комсомола, 8-3','2024-09-02');
UPDATE reader SET is_active = 0 WHERE card_number = 'R-0007';

INSERT INTO employee (last_name, first_name, middle_name, position, department_id, hire_date, phone) VALUES
 ('Кузнецова','Ирина',  'Валерьевна','Заведующая библиотекой',        1,'2015-03-01','+7 902 500-00-01'),
 ('Смирнова', 'Татьяна','Юрьевна',   'Библиотекарь абонемента',       1,'2018-08-20','+7 902 500-00-02'),
 ('Попов',    'Сергей', 'Аркадьевич','Библиотекарь читального зала',  2,'2020-01-13','+7 902 500-00-03'),
 ('Орлова',   'Наталья','Викторовна','Библиотекарь научного отдела',  3,'2021-09-01','+7 902 500-00-04');

-- Выдачи, которые уже ВОЗВРАЩЕНЫ (вставляем первыми)
INSERT INTO loan (copy_id, reader_id, employee_id, issue_date, due_date, return_date) VALUES
 ( 1, 1, 2,'2025-09-10','2025-09-24','2025-09-22'),
 ( 4, 2, 2,'2025-10-01','2025-10-15','2025-10-14'),
 (10, 3, 2,'2025-10-05','2025-10-19','2025-10-30'),   -- с просрочкой
 (18, 5, 4,'2025-11-03','2025-11-17','2025-11-17'),
 ( 7, 6, 2,'2025-11-10','2025-11-24','2025-11-21'),
 (15, 4, 2,'2025-12-01','2025-12-15','2025-12-12'),
 (21, 9, 4,'2026-01-12','2026-01-26','2026-02-03'),   -- с просрочкой
 ( 3, 8, 2,'2026-02-02','2026-02-16','2026-02-15'),
 (23,10, 4,'2026-03-09','2026-03-23','2026-03-20'),
 ( 6, 1, 2,'2026-04-14','2026-04-28','2026-04-27'),
 (17, 2, 2,'2026-05-05','2026-05-19','2026-05-18'),
 (13, 4, 2,'2026-06-01','2026-06-15','2026-06-15');

-- Выдачи, которые ещё НА РУКАХ (триггер переведёт экземпляры в «выдан»)
INSERT INTO loan (copy_id, reader_id, employee_id, issue_date, due_date, return_date) VALUES
 ( 5, 3, 2,'2026-09-15','2026-10-13', NULL),
 (11, 5, 2,'2026-09-20','2026-10-04', NULL),
 (19, 9, 4,'2026-09-22','2026-10-06', NULL),
 (16, 6, 2,'2026-08-25','2026-09-08', NULL),           -- просрочена
 (14,10, 2,'2026-08-30','2026-09-13', NULL),           -- просрочена
 (24, 1, 4,'2026-09-25','2026-10-09', NULL);

INSERT INTO fine (loan_id, amount, reason, fine_date, is_paid) VALUES
 (3, 55.00,'Просрочка возврата на 11 дней','2025-10-30',1),
 (7, 40.00,'Просрочка возврата на 8 дней', '2026-02-03',1);

-- ---------------------------------------------------------------------
-- 5. ПРИМЕРЫ ЗАПРОСОВ (для отчёта)
-- ---------------------------------------------------------------------
-- Q1. Книги, доступные сейчас:
--   SELECT title, authors, available_copies FROM v_book_availability WHERE available_copies > 0 ORDER BY title;
-- Q2. Должники:
--   SELECT * FROM v_overdue_loans ORDER BY days_overdue DESC;
-- Q3. Самые популярные книги:
--   SELECT b.title, COUNT(*) AS cnt FROM loan l JOIN book_copy c USING(copy_id) JOIN book b USING(book_id)
--   GROUP BY b.book_id ORDER BY cnt DESC LIMIT 5;
-- Q4. Книги автора:
--   SELECT b.title FROM book b JOIN book_author ba USING(book_id) JOIN author a USING(author_id) WHERE a.last_name='Толстой';
-- Q5. Сколько книг у каждого читателя на руках:
--   SELECT r.last_name, COUNT(l.loan_id) FROM reader r LEFT JOIN loan l ON l.reader_id=r.reader_id AND l.return_date IS NULL GROUP BY r.reader_id;
