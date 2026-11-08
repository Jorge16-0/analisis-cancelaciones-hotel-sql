-- =====================================================================
-- Proyecto SQL: Análisis de Cancelaciones en Hotel DataAndino (Databricks)
-- Todas las consultas del proyecto, en orden de ejecución
-- =====================================================================

-- =====================================================================
-- 00_SETUP: Preparación del entorno en Databricks
-- Proyecto Final: Análisis de Cancelaciones - Hotel DataAndino
-- =====================================================================
-- Ejecuta este script UNA sola vez antes de los ejercicios.
-- Supuesto: subiste el CSV (hotel_bookings.csv) a Databricks como la
-- tabla workspace.hotel_db.tb_reservas_raw
-- (Catalog > Create table > Upload file). Si ya tienes tb_reservas, ajusta
-- el nombre de la tabla de origen.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS workspace.hotel_db;
USE workspace.hotel_db;

-- ---------------------------------------------------------------------
-- Tabla principal tb_reservas
--  * children viene como texto ('NA') en el CSV  -> se convierte a INT
--  * arrival_date: fecha de llegada armada desde año, mes (texto) y día
--  * reservation_status_date se asegura como DATE
--  * id_reserva / id_vendedor: claves para los ejercicios de JOIN 15 y 16
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE tb_reservas AS
SELECT
  r.* EXCEPT (children, reservation_status_date, adr),
  TRY_CAST(r.children AS INT)                    AS children,
  CAST(r.adr AS DOUBLE)                          AS adr,
  TO_DATE(CAST(r.reservation_status_date AS STRING)) AS reservation_status_date,
  TO_DATE(CONCAT(r.arrival_date_year, '-', r.arrival_date_month, '-',
                 r.arrival_date_day_of_month), 'yyyy-MMMM-d') AS arrival_date,
  ROW_NUMBER() OVER (ORDER BY r.arrival_date_year, r.arrival_date_week_number,
                              r.arrival_date_day_of_month, r.hotel, r.lead_time) AS id_reserva
FROM tb_reservas_raw r;

-- Vendedor asignado (simulado): 1 de cada 10 reservas queda sin vendedor
ALTER TABLE tb_reservas ADD COLUMN id_vendedor INT;
UPDATE tb_reservas
SET id_vendedor = CASE WHEN id_reserva % 10 = 0 THEN NULL
                       ELSE CAST(id_reserva % 6 AS INT) + 1 END;

-- ---------------------------------------------------------------------
-- Tablas auxiliares (simuladas) para los ejercicios de JOIN 13 a 16
-- ---------------------------------------------------------------------

-- tb_paises (catálogo parcial: algunos códigos quedan sin nombre a propósito)
CREATE OR REPLACE TABLE tb_paises (cod_pais STRING, nombre_pais STRING);
INSERT INTO tb_paises VALUES
  ('PRT', 'Portugal'), ('GBR', 'Reino Unido'), ('FRA', 'Francia'),
  ('ESP', 'España'),   ('DEU', 'Alemania'),    ('ITA', 'Italia'),
  ('IRL', 'Irlanda'),  ('BEL', 'Bélgica'),     ('BRA', 'Brasil'),
  ('NLD', 'Países Bajos'), ('USA', 'Estados Unidos'), ('CHE', 'Suiza'),
  ('CN',  'China'),    ('AUT', 'Austria'),     ('SWE', 'Suecia'),
  ('PER', 'Perú'),     ('COL', 'Colombia'),    ('MEX', 'México');

-- tb_vendedores (el vendedor 7 no tiene reservas asignadas a propósito)
CREATE OR REPLACE TABLE tb_vendedores (id_vendedor INT, nombre_vendedor STRING);
INSERT INTO tb_vendedores VALUES
  (1, 'Ana Torres'), (2, 'Luis Quispe'), (3, 'María Rojas'),
  (4, 'Carlos Huamán'), (5, 'Rosa Mendoza'), (6, 'Jorge Salas'),
  (7, 'Valeria Ccori');

-- tb_facturas: una factura por cada reserva no cancelada (muestra de 500)
-- + 3 facturas con id_reserva inexistente para demostrar el RIGHT JOIN
CREATE OR REPLACE TABLE tb_facturas AS
SELECT
  id_reserva,
  ROUND(adr * (stays_in_weekend_nights + stays_in_week_nights), 2) AS monto_facturado
FROM tb_reservas
WHERE is_canceled = 0
ORDER BY id_reserva
LIMIT 500;

INSERT INTO tb_facturas VALUES
  (999001, 250.00), (999002, 480.50), (999003, 120.75);

-- Verificación rápida
SELECT COUNT(*) AS total_reservas, MIN(arrival_date) AS desde, MAX(arrival_date) AS hasta
FROM tb_reservas;


-- =====================================================================
-- LIMPIEZA DE DATOS: validaciones previas al análisis
-- =====================================================================
USE workspace.hotel_db;

-- Valores nulos o faltantes en columnas clave
SELECT
  SUM(CASE WHEN hotel IS NULL THEN 1 ELSE 0 END)                AS nulos_hotel,
  SUM(CASE WHEN is_canceled IS NULL THEN 1 ELSE 0 END)          AS nulos_is_canceled,
  SUM(CASE WHEN children IS NULL THEN 1 ELSE 0 END)             AS nulos_children,
  SUM(CASE WHEN country IS NULL OR country = 'NULL' THEN 1 ELSE 0 END) AS nulos_country,
  SUM(CASE WHEN adr IS NULL THEN 1 ELSE 0 END)                  AS nulos_adr,
  SUM(CASE WHEN arrival_date IS NULL THEN 1 ELSE 0 END)         AS nulos_arrival_date
FROM tb_reservas;

-- Registros duplicados (filas idénticas en todas las columnas originales)
SELECT
  COUNT(*) AS total_filas,
  COUNT(*) - (SELECT COUNT(*)
              FROM (SELECT DISTINCT * EXCEPT (id_reserva, id_vendedor)
                    FROM tb_reservas)) AS filas_duplicadas
FROM tb_reservas;

-- Valores atípicos en el precio por noche (adr)
SELECT
  SUM(CASE WHEN adr < 0  THEN 1 ELSE 0 END) AS adr_negativo,
  SUM(CASE WHEN adr = 0  THEN 1 ELSE 0 END) AS adr_cero,
  MAX(adr)                                  AS adr_maximo
FROM tb_reservas;


-- =====================================================================
-- PARTE 1: Limpieza, Exploración y Modificaciones (Ejercicios 1 al 10)
-- =====================================================================
USE workspace.hotel_db;

-- ---------------------------------------------------------------------
-- Ejercicio 1 (CREATE / INSERT)
-- Tabla de prueba con solo reservas de 'City Hotel' canceladas.
-- Nota: se crea como tabla Delta (no TEMP VIEW) porque los ejercicios
-- 2 y 6 necesitan UPDATE y DELETE, que no funcionan sobre vistas.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS tb_reservas_prueba;
CREATE TABLE tb_reservas_prueba LIKE tb_reservas;

INSERT INTO tb_reservas_prueba
SELECT *
FROM tb_reservas
WHERE hotel = 'City Hotel'
  AND is_canceled = 1;

SELECT COUNT(*) AS reservas_insertadas FROM tb_reservas_prueba;

-- ---------------------------------------------------------------------
-- Ejercicio 2 (UPDATE)
-- Corregir el error del canal: babies = 0 para todos los registros.
-- ---------------------------------------------------------------------
UPDATE tb_reservas_prueba
SET babies = 0;

SELECT SUM(babies) AS total_babies_post_update FROM tb_reservas_prueba;

-- ---------------------------------------------------------------------
-- Ejercicio 3 (CAST / CONCAT)
-- Fecha legible con formato "DD-Mes-YYYY" (ej. "25-July-2015").
-- LPAD asegura 2 dígitos en el día (01, 02, ...).
-- ---------------------------------------------------------------------
SELECT
  arrival_date_year,
  arrival_date_month,
  arrival_date_day_of_month,
  CONCAT(
    LPAD(CAST(arrival_date_day_of_month AS STRING), 2, '0'), '-',
    arrival_date_month, '-',
    CAST(arrival_date_year AS STRING)
  ) AS arrival_date_string
FROM tb_reservas;

-- ---------------------------------------------------------------------
-- Ejercicio 4 (LIKE)
-- Reservas cuyo distribution_channel empieza con 'T'.
-- ---------------------------------------------------------------------
SELECT *
FROM tb_reservas
WHERE distribution_channel LIKE 'T%';

-- ---------------------------------------------------------------------
-- Ejercicio 5 (COUNT / SUM / AVG)
-- Indicadores globales del hotel.
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                       AS total_reservas,
  SUM(total_of_special_requests) AS total_solicitudes_especiales,
  ROUND(AVG(adr), 2)             AS adr_promedio
FROM tb_reservas;

-- ---------------------------------------------------------------------
-- Ejercicio 6 (DELETE)
-- Eliminar de la tabla de pruebas las reservas con adr = 0.0.
-- ---------------------------------------------------------------------
DELETE FROM tb_reservas_prueba
WHERE adr = 0.0;

SELECT COUNT(*) AS reservas_restantes FROM tb_reservas_prueba;

-- ---------------------------------------------------------------------
-- Ejercicio 7 (GROUP BY)
-- Cantidad de reservas por canal de distribución.
-- ---------------------------------------------------------------------
SELECT
  distribution_channel,
  COUNT(*) AS cantidad_reservas
FROM tb_reservas
GROUP BY distribution_channel
ORDER BY cantidad_reservas DESC;

-- ---------------------------------------------------------------------
-- Ejercicio 8 (CASE WHEN)
-- Clasificación por precio: < 50 Económico, 50-150 Estándar, > 150 Premium.
-- ---------------------------------------------------------------------
SELECT
  hotel,
  adr,
  CASE
    WHEN adr < 50                THEN 'Económico'
    WHEN adr BETWEEN 50 AND 150  THEN 'Estándar'
    ELSE                              'Premium'
  END AS categoria_precio
FROM tb_reservas;

-- Resumen opcional de la clasificación
SELECT
  CASE
    WHEN adr < 50                THEN 'Económico'
    WHEN adr BETWEEN 50 AND 150  THEN 'Estándar'
    ELSE                              'Premium'
  END AS categoria_precio,
  COUNT(*) AS cantidad_reservas
FROM tb_reservas
GROUP BY 1
ORDER BY cantidad_reservas DESC;

-- ---------------------------------------------------------------------
-- Ejercicio 9 (DATE_SUB)
-- Fecha en que se hizo la reserva = arrival_date - lead_time días.
-- ---------------------------------------------------------------------
SELECT
  arrival_date,
  lead_time,
  DATE_SUB(arrival_date, CAST(lead_time AS INT)) AS booking_date
FROM tb_reservas;

-- ---------------------------------------------------------------------
-- Ejercicio 10 (Funciones matemáticas - CEIL)
-- Meses aproximados de anticipación, redondeados hacia arriba.
-- ---------------------------------------------------------------------
SELECT
  lead_time,
  CEIL(lead_time / 30) AS meses_anticipacion_techo
FROM tb_reservas;


-- =====================================================================
-- PARTE 2: Impacto Financiero y JOINS (Ejercicios 11 al 16)
-- =====================================================================
USE workspace.hotel_db;

-- ---------------------------------------------------------------------
-- Ejercicio 11: El costo del marketing inútil
-- USD 1.5 pagados a la agencia (TA/TO) por cada reserva cancelada.
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)       AS reservas_agencia_canceladas,
  COUNT(*) * 1.5 AS perdida_comision_usd
FROM tb_reservas
WHERE distribution_channel = 'TA/TO'
  AND is_canceled = 1;

-- ---------------------------------------------------------------------
-- Ejercicio 12: El costo de cancelar tarde (DATEDIFF)
-- Cancelaciones con menos de 3 días de anticipación -> USD 120 c/u.
-- DATEDIFF(fin, inicio) = días entre la cancelación y la llegada.
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)       AS cancelaciones_tardias,
  COUNT(*) * 120 AS perdida_operativa_usd
FROM tb_reservas
WHERE is_canceled = 1
  AND DATEDIFF(arrival_date, reservation_status_date) < 3;

-- ---------------------------------------------------------------------
-- Ejercicio 13: LEFT JOIN con tb_paises
-- Se conservan TODAS las reservas; si el país no está en el catálogo,
-- nombre_pais queda en NULL.
-- ---------------------------------------------------------------------
SELECT
  r.is_canceled,
  r.country,
  p.nombre_pais
FROM tb_reservas r
LEFT JOIN tb_paises p
  ON r.country = p.cod_pais;

-- ---------------------------------------------------------------------
-- Ejercicio 14: INNER JOIN + agrupación
-- Top 5 países con más reservas canceladas.
-- ---------------------------------------------------------------------
SELECT
  p.nombre_pais,
  COUNT(*) AS reservas_canceladas
FROM tb_reservas r
INNER JOIN tb_paises p
  ON r.country = p.cod_pais
WHERE r.is_canceled = 1
GROUP BY p.nombre_pais
ORDER BY reservas_canceladas DESC
LIMIT 5;

-- ---------------------------------------------------------------------
-- Ejercicio 15: FULL OUTER JOIN con tb_vendedores
-- Muestra reservas sin vendedor (nombre_vendedor NULL) y vendedores sin
-- reservas (distribution_channel NULL).
-- ---------------------------------------------------------------------
SELECT
  r.id_reserva,
  r.distribution_channel,
  v.nombre_vendedor
FROM tb_reservas r
FULL OUTER JOIN tb_vendedores v
  ON r.id_vendedor = v.id_vendedor;

-- Resumen para identificar los huecos del cruce
SELECT
  CASE
    WHEN r.id_reserva IS NULL      THEN 'Vendedor sin reservas'
    WHEN v.id_vendedor IS NULL     THEN 'Reserva sin vendedor'
    ELSE                                'Reserva con vendedor'
  END                           AS estado_cruce,
  COALESCE(v.nombre_vendedor, '(sin vendedor)') AS nombre_vendedor,
  COUNT(r.id_reserva)           AS cantidad_reservas
FROM tb_reservas r
FULL OUTER JOIN tb_vendedores v
  ON r.id_vendedor = v.id_vendedor
GROUP BY 1, 2
ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- Ejercicio 16: RIGHT JOIN hacia tb_facturas
-- Garantiza ver TODAS las facturas; si la factura no tiene reserva,
-- hotel queda en NULL (factura huérfana).
-- ---------------------------------------------------------------------
SELECT
  f.id_reserva,
  f.monto_facturado,
  r.hotel
FROM tb_reservas r
RIGHT JOIN tb_facturas f
  ON r.id_reserva = f.id_reserva
ORDER BY r.hotel NULLS FIRST, f.id_reserva;


-- =====================================================================
-- PARTE 3: Validación de Hipótesis de Cancelación (Ejercicios 17 al 20)
-- =====================================================================
USE workspace.hotel_db;

-- ---------------------------------------------------------------------
-- Ejercicio 17 - Hipótesis 1: ¿Los hijos aseguran el viaje?
-- COALESCE evita que un children NULL clasifique mal la reserva.
-- ---------------------------------------------------------------------
SELECT
  CASE
    WHEN COALESCE(children, 0) > 0 OR COALESCE(babies, 0) > 0 THEN 'Con Hijos'
    ELSE 'Sin Hijos'
  END                                   AS segmento,
  COUNT(*)                              AS total_reservas,
  SUM(is_canceled)                      AS reservas_canceladas,
  ROUND(AVG(is_canceled) * 100, 2)      AS tasa_cancelacion_pct
FROM tb_reservas
GROUP BY 1
ORDER BY tasa_cancelacion_pct DESC;

-- ---------------------------------------------------------------------
-- Ejercicio 18 - Hipótesis 2: El impacto de las solicitudes especiales
-- ---------------------------------------------------------------------
SELECT
  total_of_special_requests,
  COUNT(*)                              AS total_reservas,
  ROUND(AVG(is_canceled) * 100, 2)      AS tasa_cancelacion_pct
FROM tb_reservas
GROUP BY total_of_special_requests
ORDER BY total_of_special_requests ASC;

-- ---------------------------------------------------------------------
-- Ejercicio 19 - Hipótesis 3: ¿Cambiar la reserva es señal de compromiso?
-- ---------------------------------------------------------------------
SELECT
  CASE
    WHEN booking_changes = 0              THEN 'Sin Cambios'
    WHEN booking_changes BETWEEN 1 AND 3  THEN '1 a 3 cambios'
    ELSE                                       'Más de 3 cambios'
  END                                   AS grupo_cambios,
  COUNT(*)                              AS total_reservas,
  ROUND(AVG(is_canceled) * 100, 2)      AS tasa_cancelacion_pct
FROM tb_reservas
GROUP BY 1
ORDER BY tasa_cancelacion_pct ASC;

-- ---------------------------------------------------------------------
-- Ejercicio 20 - Hipótesis 4: El factor precio (adr)
-- Cancelaciones totales y ADR promedio solo de reservas canceladas.
-- ---------------------------------------------------------------------
SELECT
  hotel,
  SUM(is_canceled)                                      AS total_cancelaciones,
  ROUND(AVG(CASE WHEN is_canceled = 1 THEN adr END), 2) AS adr_promedio_canceladas
FROM tb_reservas
GROUP BY hotel
ORDER BY adr_promedio_canceladas DESC;


