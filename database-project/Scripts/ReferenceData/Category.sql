MERGE catalog.Category AS t
USING (VALUES
    (1, N'Hiking Boots', N'Footwear'), (2, N'Trail Runners', N'Footwear'), (3, N'Sandals', N'Footwear'),
    (4, N'Rain Jackets', N'Clothing'), (5, N'Insulated Jackets', N'Clothing'), (6, N'Base Layers', N'Clothing'),
    (7, N'Hiking Pants', N'Clothing'), (8, N'Tents', N'Camping'), (9, N'Sleeping Bags', N'Camping'),
    (10, N'Sleeping Pads', N'Camping'), (11, N'Stoves', N'Camping'), (12, N'Daypacks', N'Packs'),
    (13, N'Backpacking Packs', N'Packs'), (14, N'Headlamps', N'Electronics'), (15, N'GPS Devices', N'Electronics'),
    (16, N'Harnesses', N'Climbing'), (17, N'Ropes', N'Climbing'), (18, N'Water Filters', N'Camping')
) AS s (CategoryID, CategoryName, Department)
ON t.CategoryID = s.CategoryID
WHEN MATCHED AND (t.CategoryName <> s.CategoryName OR t.Department <> s.Department) THEN
    UPDATE SET CategoryName = s.CategoryName, Department = s.Department
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CategoryID, CategoryName, Department) VALUES (s.CategoryID, s.CategoryName, s.Department);
-- No "WHEN NOT MATCHED BY SOURCE THEN DELETE": categories are referenced by products, so removals are
-- handled deliberately (retire the products first) instead of by every deployment.
