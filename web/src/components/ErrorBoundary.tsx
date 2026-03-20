import { Component, ComponentChildren } from "preact";

interface Props {
  children: ComponentChildren;
}

interface State {
  error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  render() {
    if (this.state.error) {
      return (
        <div class="error-boundary">
          <h2>Something went wrong</h2>
          <pre class="error-boundary-message">{this.state.error.message}</pre>
          <pre class="error-boundary-stack">{this.state.error.stack}</pre>
          <button
            class="error-boundary-reset"
            onClick={() => {
              this.setState({ error: null });
            }}
          >
            Try Again
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}
