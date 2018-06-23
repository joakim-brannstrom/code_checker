module state_machine.test.common;

import state_machine;

version (unittest) {
    struct Order {
        mixin StateMachine!(status, "pending", "ordered", "paid");

    private:
        int status;

        double balance = 0;
        double total = 0;

        @BeforeTransition("ordered")
        bool isPendingAndTotalNonZero() {
            return this.pending && total > 0;
        }

        @AfterTransition("ordered")
        void setBalanceFromTotal() {
            balance = total;
        }

        @BeforeTransition("paid")
        bool isOrderedAndBalanceZero() {
            return this.ordered && balance == 0;
        }
    }
}

static unittest {
    Order o;

    static assert(is(typeof(o.statusNames()) == string[]));

    static assert(is(typeof(o.pending()) == bool));
    static assert(is(typeof(o.ordered()) == bool));
    static assert(is(typeof(o.paid()) == bool));

    static assert(is(typeof(o.toPending()) == bool));
    static assert(is(typeof(o.toOrdered()) == bool));
    static assert(is(typeof(o.toPaid()) == bool));
}

unittest {
    Order o;

    assert(o.statusNames == ["pending", "ordered", "paid"]);
    assert(o.statusValues == ["pending" : 0, "ordered" : 1, "paid" : 2]);

    assert(o.status == 0);
    assert(o.pending is true);
    assert(o.ordered is false);
    assert(o.paid is false);

    assert(o.total == 0);
    assert(o.toOrdered is false);
    assert(o.pending is true);

    o.total = 5000;
    assert(o.total == 5000);
    assert(o.toOrdered is true);
    assert(o.ordered is true);
    assert(o.pending is false);
    assert(o.balance == o.total);

    assert(o.balance != 0);
    assert(o.toPaid is false);
    assert(o.ordered is true);

    o.balance = 0;
    assert(o.balance == 0);
    assert(o.toPaid is true);
    assert(o.paid is true);
    assert(o.ordered is false);
}

version (unittest) {
    class Product {
        mixin StateMachine!(status, "inactive", "active", "deleted");

    private:
        string status = "inactive";

        string name;
        string description;
        double price = 0;

        @BeforeTransition("active")
        bool hasNameAndDescription() {
            return name != null && description != null;
        }

        @BeforeTransition bool isNotSoftDeleted() {
            return !this.deleted;
        }
    }
}

static unittest {
    Product p;

    static assert(is(typeof(p.statusNames()) == string[]));

    static assert(is(typeof(p.inactive()) == bool));
    static assert(is(typeof(p.active()) == bool));
    static assert(is(typeof(p.deleted()) == bool));

    static assert(is(typeof(p.toInactive()) == bool));
    static assert(is(typeof(p.toActive()) == bool));
    static assert(is(typeof(p.toDeleted()) == bool));
}

unittest {
    Product p = new Product;

    assert(p.status == "inactive");
    assert(p.name is null);
    assert(p.description is null);
    assert(p.price == 0);

    assert(p.inactive is true);
    assert(p.active is false);
    assert(p.deleted is false);

    assert(p.toActive is false);
    assert(p.inactive is true);

    p.name = "Pizza";
    p.description = "Cheese";
    p.price = 15.99;
    assert(p.toActive is true);
    assert(p.inactive is false);
    assert(p.active is true);

    assert(p.toDeleted is true);
    assert(p.deleted is true);

    assert(p.toActive is false);
    assert(p.deleted is true);

    assert(p.toInactive is false);
    assert(p.deleted is true);
}

version (unittest) {
    enum UserStatus : string {
        none = null,
        registered = "registered",
        confirmed = "confirmed",
        banned = "banned"
    }

    struct User {
        mixin StateMachine!status;

        UserStatus status;

        string email;
        bool confirmationSent;

        string password;
        string reason;

        @BeforeTransition("registered")
        bool isNewUserAndHasEmailAddress() {
            return this.none && email.length != 0;
        }

        @AfterTransition("registered")
        void sendEmailConfirmation() {
            // TODO : mailer.send("email_confirmation");
            confirmationSent = true;
        }

        @BeforeTransition("confirmed")
        bool isRegisteredAndSetPassword() {
            return this.registered && password.length >= 6;
        }

        @BeforeTransition("banned")
        bool isBanReasonGiven() {
            return reason.length != 0;
        }
    }
}

static unittest {
    User u;

    static assert(is(typeof(u.statusNames()) == string[]));

    static assert(is(typeof(u.none()) == bool));
    static assert(is(typeof(u.registered()) == bool));
    static assert(is(typeof(u.confirmed()) == bool));
    static assert(is(typeof(u.banned()) == bool));

    static assert(is(typeof(u.toNone()) == bool));
    static assert(is(typeof(u.toRegistered()) == bool));
    static assert(is(typeof(u.toConfirmed()) == bool));
    static assert(is(typeof(u.toBanned()) == bool));
}

unittest {
    User u;

    assert(u.statusNames == ["none", "registered", "confirmed", "banned"]);
    assert(u.statusValues == ["none" : UserStatus.none, "registered" : UserStatus.registered,
            "confirmed" : UserStatus.confirmed, "banned" : UserStatus.banned]);

    assert(u.status is null);
    assert(u.email is null);
    assert(u.password is null);
    assert(u.reason is null);
    assert(u.confirmationSent is false);

    assert(u.none is true);
    assert(u.registered is false);
    assert(u.confirmed is false);
    assert(u.banned is false);

    assert(u.toRegistered is false);
    assert(u.registered is false);
    assert(u.none is true);

    u.email = "webmaster@john.smith.com";
    assert(u.toRegistered is true);
    assert(u.registered is true);
    assert(u.none is false);
    assert(u.confirmationSent is true);

    assert(u.toConfirmed is false);
    assert(u.confirmed is false);
    assert(u.registered is true);

    u.password = "foo bar";
    assert(u.toConfirmed is true);
    assert(u.confirmed is true);
    assert(u.registered is false);

    assert(u.toBanned is false);
    assert(u.confirmed is true);
    assert(u.banned is false);

    u.reason = "Spam";
    assert(u.toBanned is true);
    assert(u.banned is true);
    assert(u.confirmed is false);
}

version (unittest) {
    struct Message {
        mixin StateMachine!(status, "unsent", "draft", "sent", "opened");

    private:
        uint _status;

        string title;
        string content;

    public:
        @property uint status() const {
            return _status;
        }

        @property uint status(uint status) {
            return _status = status;
        }
    }
}

unittest {
    Message m;

    assert(m.statusNames == ["unsent", "draft", "sent", "opened"]);

    assert(m.status == 0);
    assert(m.title is null);
    assert(m.content is null);
    assert(m.unsent is true);

    assert(m.toDraft is true);
    assert(m.draft is true);
    assert(m.unsent is false);
}
