-- Native USDC movements that did not go through the ERC-20 interface. A transfer through 0x3600
-- logs twice (6 decimals there, 18 from the system emitter); this keeps only the emitter's log with
-- no ERC-20 twin in the same transaction, so the two tables can be added without double counting.
CREATE VIEW native_only AS
  SELECT n.*
  FROM native__transfer n
  WHERE NOT EXISTS (
    SELECT 1 FROM usdc__transfer u
    WHERE u.tx_hash = n.tx_hash
      AND u."from" = n."from"
      AND u."to" = n."to"
      AND u.value_dec * 1000000000000 = n.value_dec
  );
