# state-machine
Turn any type into a state machine.

## Example

A simple example of a state machine would be as follows.

```d
import state_machine;

struct Order
{
    // Turn order into a state-machine with 3 states.
    mixin StateMachine!(status, "pending", "ordered", "paid");
    
    uint status;
}
```

Mixing in `StateMachine` gives our type functions to check its current state, as well as ones to control its transitions between states.

```d
void main()
{
    Order o;
    
    assert(o.pending is true);
    assert(o.ordered is false);
    
    // Change status to ordered.
    assert(o.toOrdered() is true);

    assert(o.pending is false);
    assert(o.ordered is true);
}
```

### Callbacks

You can also define callbacks to control transitions between states, as well as update fields in response to transitions.

```d
import state_machine;

struct Order
{
    // Turn order into a state-machine with 3 states.
    mixin StateMachine!(status, "pending", "ordered", "paid");
    
    uint status;
    
    double total   = 0;
    double balance = 0;
    
    @BeforeTransition("ordered")
    bool isPendingAndTotalNonZero()
    {
        return this.pending && total > 0;
    }
    
    @AfterTransition("ordered")
    void setBalanceFromTotal()
    {
        balance = total;
    }
    
    @BeforeTransition("paid")
    bool isOrderedAndBalanceZero()
    {
        return this.ordered && balance == 0;
    }
}
```

Now `Order` requires a non-zero total to be transition to the `ordered` state, and a zero balance to become `paid`. In addition, the balance is automatically set when transitioning from pending to ordered.

```d
void main()
{
    Order o;
    
    assert(o.pending is true);
    assert(o.toOrdered() is false);
    
    // Requires non-zero total.
    o.total = 50.00;
    assert(o.toOrdered() is true);

    // Balance is auto-set.
    assert(o.balance == 50.00);
    assert(o.toPaid() is false);

    // Balance must be zero.
    o.balance = 0;
    assert(o.toPaid() is true);
}
```

`StateMachine` operates on a given state field, which can be an `int` (or covariant type), a `string`, an `enum` type, or a `@property` of one of those 3 types. It also exposes some helpful meta-functions.

```d
void main()
{
    Order o;

    assert(o.statusNames == ["pending", "ordered", "paid"]);
    assert(o.statusValues == [
        "pending": 0,
        "ordered": 1,
        "paid": 2
    ]);
}
```

## License

MIT
