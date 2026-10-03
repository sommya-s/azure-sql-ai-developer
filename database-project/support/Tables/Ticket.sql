CREATE TABLE support.Ticket
(
    TicketID   int            NOT NULL CONSTRAINT PK_Ticket PRIMARY KEY CLUSTERED,
    CustomerID int            NOT NULL CONSTRAINT FK_Ticket_Customer REFERENCES crm.Customer (CustomerID),
    ProductID  int            NULL     CONSTRAINT FK_Ticket_Product REFERENCES catalog.Product (ProductID),
    OrderID    bigint         NULL     CONSTRAINT FK_Ticket_Order REFERENCES sales.SalesOrder (OrderID),
    OpenedAt   datetime2(0)   NOT NULL,
    Channel    varchar(10)    NOT NULL CONSTRAINT CK_Ticket_Channel CHECK (Channel IN ('Email', 'Chat', 'Phone')),
    Subject    nvarchar(200)  NOT NULL,
    Body       nvarchar(4000) NOT NULL,
    Status     varchar(10)    NOT NULL CONSTRAINT CK_Ticket_Status CHECK (Status IN ('Open', 'Pending', 'Resolved', 'Closed')),
    Priority   varchar(10)    NOT NULL CONSTRAINT CK_Ticket_Priority CHECK (Priority IN ('Low', 'Medium', 'High', 'Urgent'))
);
