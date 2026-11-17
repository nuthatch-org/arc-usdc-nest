-- Every native USDC movement per hour, from the system emitter, which logs all of them. value_raw
-- has 18 decimals. Mints come from and burns go to the zero address.
CREATE VIEW movements_hourly AS
  SELECT block_timestamp - (block_timestamp % 3600) AS hour,
         count(*) AS movements,
         sum(CASE WHEN "from" = '0x0000000000000000000000000000000000000000' THEN 1 ELSE 0 END) AS mints,
         sum(CASE WHEN "to" = '0x0000000000000000000000000000000000000000' THEN 1 ELSE 0 END) AS burns,
         sum(value_dec) AS value_raw
  FROM native__transfer
  GROUP BY block_timestamp - (block_timestamp % 3600);
