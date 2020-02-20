defmodule Model.TicketSql do
  alias Model.Sql
  alias Object.Ticket

  defp query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  defp with_transaction(fun) do
    Sql.with_transaction(__MODULE__, fun)
  end

  def init() do
    with_transaction(fn db ->
      Sql.query!(db, """
          CREATE TABLE IF NOT EXISTS tickets (
            device BLOB,
            fleet BLOB,
            epoch INTEGER,
            ticket BLOB,
            PRIMARY KEY (device, fleet, epoch)
          )
      """)

      Sql.query!(db, """
          CREATE INDEX IF NOT EXISTS tck_epoch ON tickets (
            epoch
          )
      """)
    end)
  end

  def put_ticket(ticket) do
    ticket_data = BertInt.encode!(ticket)

    query!("REPLACE INTO tickets (device, fleet, epoch, ticket) VALUES(?1, ?2, ?3, ?4)",
      bind: [
        Ticket.device_address(ticket),
        Ticket.fleet_contract(ticket),
        Ticket.epoch(ticket),
        ticket_data
      ]
    )

    ticket
  end

  def tickets_raw() do
    query!("SELECT device, fleet, epoch, ticket FROM tickets")
    |> Enum.map(fn [device: dev, fleet: fleet, epoch: epoch, ticket: ticket] ->
      {dev, fleet, epoch, BertInt.decode!(ticket)}
    end)
  end

  def tickets(epoch) do
    query!("SELECT ticket FROM tickets WHERE epoch = ?1", bind: [epoch])
    |> Enum.map(fn [ticket: ticket] -> BertInt.decode!(ticket) end)
  end

  def find(tck) do
    find(Ticket.device_address(tck), Ticket.fleet_contract(tck), Ticket.epoch(tck))
  end

  def find(device = <<_::160>>, fleet = <<__::160>>, epoch) when is_integer(epoch) do
    Sql.fetch!(
      __MODULE__,
      "SELECT ticket FROM tickets WHERE device = ?1 AND fleet = ?2 AND epoch = ?3",
      [device, fleet, epoch]
    )
  end

  def delete(tck) do
    delete(Ticket.device_address(tck), Ticket.fleet_contract(tck), Ticket.epoch(tck))
  end

  def delete(device = <<_::160>>, fleet = <<__::160>>, epoch) when is_integer(epoch) do
    query!(
      "DELETE FROM tickets WHERE device = ?1 AND fleet = ?2 AND epoch = ?3",
      bind: [device, fleet, epoch]
    )
  end

  def delete_old(epoch) do
    query!("DELETE FROM tickets WHERE epoch < ?1", bind: [epoch])
  end

  def delete_all() do
    query!("DELETE FROM tickets")
  end
end
