MERGE sales.Store AS t
USING (VALUES
    (1, 'RIX01', N'Trailhead Riga Old Town', N'Riga', N'Latvia', 'Baltics', '2019-04-12'),
    (2, 'RIX02', N'Trailhead Riga Spice', N'Riga', N'Latvia', 'Baltics', '2021-09-01'),
    (3, 'VNO01', N'Trailhead Vilnius', N'Vilnius', N'Lithuania', 'Baltics', '2020-03-15'),
    (4, 'TLL01', N'Trailhead Tallinn', N'Tallinn', N'Estonia', 'Baltics', '2020-06-20'),
    (5, 'HEL01', N'Trailhead Helsinki', N'Helsinki', N'Finland', 'Nordics', '2021-02-10'),
    (6, 'STO01', N'Trailhead Stockholm', N'Stockholm', N'Sweden', 'Nordics', '2022-05-05'),
    (7, 'OSL01', N'Trailhead Oslo', N'Oslo', N'Norway', 'Nordics', '2022-11-18'),
    (8, 'BER01', N'Trailhead Berlin', N'Berlin', N'Germany', 'Central Europe', '2023-03-01'),
    (9, 'MUC01', N'Trailhead Munich', N'Munich', N'Germany', 'Central Europe', '2023-08-24'),
    (10, 'WAW01', N'Trailhead Warsaw', N'Warsaw', N'Poland', 'Central Europe', '2024-01-15'),
    (11, 'KRK01', N'Trailhead Krakow', N'Krakow', N'Poland', 'Central Europe', '2024-06-01'),
    (12, 'INN01', N'Trailhead Innsbruck', N'Innsbruck', N'Austria', 'Central Europe', '2025-04-04')
) AS s (StoreID, StoreCode, StoreName, City, Country, Region, OpenedOn)
ON t.StoreID = s.StoreID
WHEN MATCHED AND (t.StoreName <> s.StoreName OR t.City <> s.City OR t.Region <> s.Region) THEN
    UPDATE SET StoreCode = s.StoreCode, StoreName = s.StoreName, City = s.City, Country = s.Country,
               Region = s.Region, OpenedOn = s.OpenedOn
WHEN NOT MATCHED BY TARGET THEN
    INSERT (StoreID, StoreCode, StoreName, City, Country, Region, OpenedOn)
    VALUES (s.StoreID, s.StoreCode, s.StoreName, s.City, s.Country, s.Region, s.OpenedOn);
